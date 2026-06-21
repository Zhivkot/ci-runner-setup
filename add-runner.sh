#!/usr/bin/env bash
#
# Add a self-hosted GitHub Actions runner for ANY repo to the existing EC2 box
# — run from your LAPTOP, give it a repo name, done:
#
#   bash add-runner.sh Zhivkot/my-cdk-project
#   bash add-runner.sh Zhivkot/my-cdk-project self-hosted,linux,arm64,cdk
#
# It mints the registration token with your local `gh` (reuses your repo-admin
# login — no PAT to manage), finds the runner instance by tag, and installs the
# runner ON the box over **SSM** (no SSH, no inbound ports, no key). Each repo
# gets its own runner directory + systemd service, so they coexist on one host.
#
# Prereqs (laptop):
#   - gh CLI, logged in with admin on the target repo  (gh auth status)
#   - aws CLI, creds with ec2:DescribeInstances + ssm:SendCommand/GetCommandInvocation
#   - the box must be SSM-reachable — run `bash enable-ssm.sh` ONCE first
#
# Everything is a variable; nothing about the repo is hard-coded.
#
set -euo pipefail

# ── inputs (positional or env) ─────────────────────────────────────────────
REPO="${1:-${REPO:-}}"                                  # owner/repo  (required)
LABELS="${2:-${LABELS:-self-hosted,linux,arm64}}"       # workflow targets these
REGION="${REGION:-eu-central-1}"
NAME_TAG="${NAME_TAG:-gha-runner}"                       # EC2 instance Name tag
RUNNER_USER="${RUNNER_USER:-ec2-user}"                  # unprivileged owner on the box
INSTANCE_ID="${INSTANCE_ID:-}"                          # skip tag lookup if set
export MSYS_NO_PATHCONV=1                               # Git-Bash: don't mangle gh/aws paths

case "$REPO" in
  */*) ;;
  *) echo "Usage: bash add-runner.sh <owner/repo> [labels]" >&2; exit 1 ;;
esac
SLUG="$(printf '%s' "$REPO" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
RUNNER_NAME="${RUNNER_NAME:-gha-${SLUG}}"

# python3 on the box; locally it may be python3 or python.
PY="$(command -v python3 || command -v python || true)"
command -v gh  >/dev/null || { echo "gh not found" >&2; exit 1; }
command -v aws >/dev/null || { echo "aws not found" >&2; exit 1; }
[ -n "$PY" ] || { echo "python (3) not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not logged in — run: gh auth login" >&2; exit 1; }

echo "Repo=$REPO  Runner=$RUNNER_NAME  Labels=$LABELS  Region=$REGION"

# ── 1. mint a registration token with your local gh (no PAT) ───────────────
echo "Minting registration token…"
TOKEN="$(gh api -X POST "repos/${REPO}/actions/runners/registration-token" --jq '.token')"
[ -n "$TOKEN" ] || { echo "Couldn't mint a token (need admin on ${REPO})." >&2; exit 1; }

# ── 2. find the runner instance ────────────────────────────────────────────
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${NAME_TAG}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
fi
[ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ] || {
  echo "No running instance tagged Name=${NAME_TAG} in ${REGION} (set INSTANCE_ID=…)." >&2; exit 1; }
if [ "$(printf '%s' "$INSTANCE_ID" | wc -w)" -ne 1 ]; then
  echo "Multiple instances match (${INSTANCE_ID}); set INSTANCE_ID=… to disambiguate." >&2; exit 1
fi
echo "Instance=$INSTANCE_ID"

# ── 3. confirm SSM can reach it ────────────────────────────────────────────
PING="$(aws ssm describe-instance-information --region "$REGION" \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)"
[ "$PING" = "Online" ] || {
  echo "Instance ${INSTANCE_ID} is not reachable over SSM (PingStatus=${PING})." >&2
  echo "Run this once to enable it:  bash enable-ssm.sh" >&2; exit 1; }

# ── 4. build the on-box install script (runs as root via SSM) ──────────────
# Injected values ($REPO/$TOKEN/...) are expanded now; the runner's own
# internal vars (\$DIR, \$VER, \$A) are escaped so they evaluate on the box.
# Temp files in the CWD (relative paths) — native aws.exe on Git-Bash can't
# read a Unix /tmp paramfile path for `--parameters file://…`.
REMOTE_SH="./.add-runner-remote.$$.sh"; PARAMS="./.add-runner-params.$$.json"
trap 'rm -f "$REMOTE_SH" "$PARAMS"' EXIT
cat > "$REMOTE_SH" <<REMOTE
#!/bin/bash
set -e
RUNNER_USER="${RUNNER_USER}"
DIR="/home/\${RUNNER_USER}/runners/${SLUG}"
if [ -e "\${DIR}/config.sh" ]; then
  echo "A runner dir already exists at \${DIR} — remove it first." >&2; exit 1
fi
VER=\$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['tag_name'][1:])")
case "\$(uname -m)" in
  aarch64|arm64) A=arm64 ;;
  x86_64|amd64)  A=x64   ;;
  *) echo "unsupported arch \$(uname -m)" >&2; exit 1 ;;
esac
mkdir -p "\${DIR}"
curl -fsSL -o "\${DIR}/r.tgz" \
  "https://github.com/actions/runner/releases/download/v\${VER}/actions-runner-linux-\${A}-\${VER}.tar.gz"
tar xzf "\${DIR}/r.tgz" -C "\${DIR}"; rm -f "\${DIR}/r.tgz"
chown -R "\${RUNNER_USER}:\${RUNNER_USER}" "\${DIR}"
cd "\${DIR}"
# config.sh refuses root → run as the runner user; svc.sh install needs root (we are root via SSM).
sudo -u "\${RUNNER_USER}" ./config.sh \
  --url "https://github.com/${REPO}" --token "${TOKEN}" \
  --name "${RUNNER_NAME}" --labels "${LABELS}" \
  --work _work --unattended --replace
./svc.sh install "\${RUNNER_USER}"
./svc.sh start
echo "RUNNER_ADDED_OK ${RUNNER_NAME}"
REMOTE

# ── 5. send it to the box over SSM (params via file → no shell-quoting hell) ─
"$PY" - "$REMOTE_SH" > "$PARAMS" <<'PYEOF'
import json, sys
print(json.dumps({"commands": [open(sys.argv[1], encoding="utf-8").read()]}))
PYEOF

echo "Sending install command via SSM…"
CMD_ID="$(aws ssm send-command --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "add runner ${REPO}" \
  --parameters "file://${PARAMS}" \
  --query 'Command.CommandId' --output text)"
echo "Command=$CMD_ID — waiting…"

# ── 6. wait for it + surface the output ────────────────────────────────────
STATUS="Pending"
for _ in $(seq 1 60); do
  STATUS="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "$STATUS" in
    Success) break ;;
    Failed|Cancelled|TimedOut) break ;;
  esac
  sleep 5
done
# Best-effort output capture — guard every external call so set -e/pipefail
# can't abort the script on a transient API hiccup (these are just reporting).
OUT="$(aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text 2>/dev/null || true)"
echo "--- box output ---"; printf '%s\n' "$OUT" | tail -5
ERR="$(aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardErrorContent' --output text 2>/dev/null || true)"
if [ -n "${ERR//[[:space:]]/}" ]; then echo "--- stderr ---"; printf '%s\n' "$ERR" | tail -5; fi
echo "------------------"
if [ "$STATUS" != "Success" ]; then echo "SSM command ended: ${STATUS}." >&2; exit 1; fi

# ── 7. verify the runner registered + came online ──────────────────────────
echo "Verifying registration…"
for _ in $(seq 1 12); do
  ST="$(gh api "repos/${REPO}/actions/runners" \
    --jq ".runners[] | select(.name==\"${RUNNER_NAME}\") | .status" 2>/dev/null || true)"
  if [ "$ST" = "online" ]; then echo "Runner '${RUNNER_NAME}' online ✓"; break; fi
  sleep 5
done

echo
echo "Done. ${REPO} now has runner '${RUNNER_NAME}' on ${INSTANCE_ID}."
echo "Point its workflow at:  runs-on: [self-hosted, Linux, ARM64]"
echo "Heads-up: extra runners can run jobs in parallel and share this box's"
echo "RAM (t4g.medium = 4 GB) — avoid two heavy builds at once."
