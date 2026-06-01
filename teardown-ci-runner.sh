#!/usr/bin/env bash
#
# Deregister the GitHub runner(s) named $RUNNER_NAME and terminate the tagged
# EC2 instance(s). Asks for confirmation before terminating.
#
set -euo pipefail
REPO="${REPO:-Zhivkot/my-consultation-site}"
REGION="${REGION:-eu-central-1}"
RUNNER_NAME="${RUNNER_NAME:-gha-ec2-runner}"
NAME_TAG="${NAME_TAG:-gha-runner}"
export MSYS_NO_PATHCONV=1

echo "Repo=$REPO  Region=$REGION"

# Instances tagged Name=$NAME_TAG (running or stopped).
IIDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${NAME_TAG}" \
            "Name=instance-state-name,Values=running,stopped,stopping" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
echo "Instances: ${IIDS:-<none>}"

# Runner registrations with the configured name.
RIDS=$(gh api "repos/${REPO}/actions/runners" \
  --jq ".runners[] | select(.name==\"${RUNNER_NAME}\") | .id" 2>/dev/null || true)
echo "Runner ids: ${RIDS:-<none>}"

if [ -z "${IIDS}${RIDS}" ]; then echo "Nothing to do."; exit 0; fi

printf 'Deregister runner(s) and TERMINATE instance(s)? (y/N) '
read -r ans
case "$ans" in [yY]*) ;; *) echo "Aborted."; exit 0;; esac

for r in $RIDS; do
  echo "Deregistering runner $r…"
  gh api -X DELETE "repos/${REPO}/actions/runners/$r"
done
for i in $IIDS; do
  echo "Terminating $i…"
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$i" \
    --query 'TerminatingInstances[0].CurrentState.Name' --output text
done
echo "Done. (Remember to point the workflow back to a runner you still have.)"
