#!/usr/bin/env bash
#
# ONE-TIME: make the runner box reachable from your laptop over SSM, so
# `add-runner.sh` can install runners on it without SSH / inbound ports / a key.
#
# It creates a minimal IAM role (AmazonSSMManagedInstanceCore), wraps it in an
# instance profile, and attaches it to the tagged instance. Idempotent — safe
# to re-run. SSM is outbound-only, so this keeps the box's "no inbound" posture.
#
# Prereqs (laptop): aws CLI with iam:CreateRole/CreatePolicy-ish + PassRole +
#   ec2:AssociateIamInstanceProfile/DescribeInstances. (The plain `amplify`
#   user may NOT have IAM rights — use an admin profile for this one-time step:
#   AWS_PROFILE=admin bash enable-ssm.sh)
#
set -euo pipefail

REGION="${REGION:-eu-central-1}"
NAME_TAG="${NAME_TAG:-gha-runner}"
INSTANCE_ID="${INSTANCE_ID:-}"
ROLE="${ROLE:-gha-runner-ssm}"
PROFILE="${PROFILE:-gha-runner-ssm}"
export MSYS_NO_PATHCONV=1

command -v aws >/dev/null || { echo "aws not found" >&2; exit 1; }

# ── find the instance ──────────────────────────────────────────────────────
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${NAME_TAG}" "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
fi
[ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ] || {
  echo "No instance tagged Name=${NAME_TAG} (set INSTANCE_ID=…)." >&2; exit 1; }
[ "$(printf '%s' "$INSTANCE_ID" | wc -w)" -eq 1 ] || {
  echo "Multiple instances (${INSTANCE_ID}); set INSTANCE_ID=…." >&2; exit 1; }
echo "Instance=$INSTANCE_ID"

# ── role (idempotent) ──────────────────────────────────────────────────────
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  echo "Creating role ${ROLE}…"
  # Inline JSON (no file://) — native aws.exe on Git-Bash can't read a Unix
  # /tmp paramfile path; passing the document inline works on every platform.
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
else
  echo "Role ${ROLE} exists."
fi
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true

# ── instance profile (idempotent) ──────────────────────────────────────────
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
  echo "Creating instance profile ${PROFILE}…"
  aws iam create-instance-profile --instance-profile-name "$PROFILE" >/dev/null
fi
# add-role is not idempotent; swallow "already in profile".
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" \
  --role-name "$ROLE" >/dev/null 2>&1 || true
echo "Waiting for the instance profile to propagate…"; sleep 10

# ── associate with the instance (skip if one is already attached) ──────────
EXISTING="$(aws ec2 describe-iam-instance-profile-associations --region "$REGION" \
  --filters "Name=instance-id,Values=${INSTANCE_ID}" \
  --query 'IamInstanceProfileAssociations[?State==`associated`].IamInstanceProfile.Arn' \
  --output text 2>/dev/null || true)"
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  echo "Instance already has an instance profile: ${EXISTING}"
  echo "(If it's not ${PROFILE}, that role just needs the AmazonSSMManagedInstanceCore policy — no replace needed.)"
else
  echo "Associating ${PROFILE} with ${INSTANCE_ID}…"
  aws ec2 associate-iam-instance-profile --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --iam-instance-profile "Name=${PROFILE}" >/dev/null
fi

# ── wait for the SSM agent to register ─────────────────────────────────────
echo "Waiting for SSM to see the instance (agent is pre-installed on AL2023; ~1–3 min)…"
for _ in $(seq 1 24); do
  PING="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)"
  [ "$PING" = "Online" ] && { echo "SSM Online ✓"; break; }
  sleep 15
done
[ "${PING:-None}" = "Online" ] || {
  echo "Still not Online. The SSM agent may need a reboot to pick up the new role:" >&2
  echo "  aws ec2 reboot-instances --region ${REGION} --instance-ids ${INSTANCE_ID}" >&2
  exit 1; }

echo
echo "Done. The box is SSM-reachable. Now add runners with:"
echo "  bash add-runner.sh <owner/repo>"
