#!/usr/bin/env bash
#
# Remove a self-hosted runner for a repo from the EC2 box — the inverse of
# add-runner.sh. Run from your LAPTOP; give it the repo name:
#
#   bash remove-runner.sh Zhivkot/my-cdk-project
#
# It mints a remove-token with your local gh, then over SSM (no SSH): stops +
# uninstalls that runner's systemd service, deregisters it from GitHub
# (config.sh remove), and deletes its directory. The other runners on the box
# are untouched. Idempotent — safe if the runner's already gone.
#
# Prereqs (laptop): gh (admin on the repo) + aws (ssm:SendCommand,
# ec2:DescribeInstances). The box must be SSM-reachable (enable-ssm.sh).
#
set -euo pipefail

REPO="${1:-${REPO:-}}"
REGION="${REGION:-eu-central-1}"
NAME_TAG="${NAME_TAG:-gha-runner}"
RUNNER_USER="${RUNNER_USER:-ec2-user}"
INSTANCE_ID="${INSTANCE_ID:-}"
export MSYS_NO_PATHCONV=1

case "$REPO" in
  */*) ;;
  *) echo "Usage: bash remove-runner.sh <owner/repo>" >&2; exit 1 ;;
esac
SLUG="$(printf '%s' "$REPO" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
RUNNER_NAME="${RUNNER_NAME:-gha-${SLUG}}"

PY="$(command -v python3 || command -v python || true)"
command -v gh  >/dev/null || { echo "gh not found" >&2; exit 1; }
command -v aws >/dev/null || { echo "aws not found" >&2; exit 1; }
[ -n "$PY" ] || { echo "python (3) not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not logged in" >&2; exit 1; }

echo "Repo=$REPO  Runner=$RUNNER_NAME  Region=$REGION"

# ── 1. mint a REMOVE token (deregisters the runner) ────────────────────────
echo "Minting remove token…"
TOKEN="$(gh api -X POST "repos/${REPO}/actions/runners/remove-token" --jq '.token')"
[ -n "$TOKEN" ] || { echo "Couldn't mint a remove token (need admin on ${REPO})." >&2; exit 1; }

# ── 2. find the instance + confirm SSM ─────────────────────────────────────
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${NAME_TAG}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
fi
[ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ] || {
  echo "No running instance tagged Name=${NAME_TAG} (set INSTANCE_ID=…)." >&2; exit 1; }
[ "$(printf '%s' "$INSTANCE_ID" | wc -w)" -eq 1 ] || {
  echo "Multiple instances (${INSTANCE_ID}); set INSTANCE_ID=…." >&2; exit 1; }
PING="$(aws ssm describe-instance-information --region "$REGION" \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)"
[ "$PING" = "Online" ] || { echo "Instance ${INSTANCE_ID} not SSM-reachable (PingStatus=${PING})." >&2; exit 1; }
echo "Instance=$INSTANCE_ID"

# ── 3. build the on-box removal script ─────────────────────────────────────
REMOTE_SH="./.remove-runner-remote.$$.sh"; PARAMS="./.remove-runner-params.$$.json"
trap 'rm -f "$REMOTE_SH" "$PARAMS"' EXIT
cat > "$REMOTE_SH" <<REMOTE
#!/bin/bash
set -e
RUNNER_USER="${RUNNER_USER}"
DIR="/home/\${RUNNER_USER}/runners/${SLUG}"
if [ ! -d "\${DIR}" ]; then echo "no runner dir \${DIR} — nothing to remove"; exit 0; fi
cd "\${DIR}"
# svc.sh needs root (we are, via SSM); config.sh refuses root → run as the user.
./svc.sh stop || true
./svc.sh uninstall || true
sudo -u "\${RUNNER_USER}" ./config.sh remove --token "${TOKEN}" || true
cd /
rm -rf "\${DIR}"
echo "RUNNER_REMOVED_OK ${RUNNER_NAME}"
REMOTE

"$PY" - "$REMOTE_SH" > "$PARAMS" <<'PYEOF'
import json, sys
print(json.dumps({"commands": [open(sys.argv[1], encoding="utf-8").read()]}))
PYEOF

echo "Sending removal command via SSM…"
CMD_ID="$(aws ssm send-command --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "remove runner ${REPO}" \
  --parameters "file://${PARAMS}" \
  --query 'Command.CommandId' --output text)"
echo "Command=$CMD_ID — waiting…"

STATUS="Pending"
for _ in $(seq 1 60); do
  STATUS="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "$STATUS" in Success) break ;; Failed|Cancelled|TimedOut) break ;; esac
  sleep 5
done
OUT="$(aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text 2>/dev/null || true)"
echo "--- box output ---"; printf '%s\n' "$OUT" | tail -5; echo "------------------"
if [ "$STATUS" != "Success" ]; then echo "SSM command ended: ${STATUS}." >&2; exit 1; fi

# ── 4. verify it's gone; belt-and-suspenders deregister by id if it lingers ─
RID="$(gh api "repos/${REPO}/actions/runners" \
  --jq ".runners[] | select(.name==\"${RUNNER_NAME}\") | .id" 2>/dev/null || true)"
if [ -n "$RID" ]; then
  echo "Runner still registered (id ${RID}) — deregistering via API…"
  gh api -X DELETE "repos/${REPO}/actions/runners/${RID}" 2>/dev/null || true
fi
echo "Done. Runner '${RUNNER_NAME}' removed from ${REPO} and the box."
