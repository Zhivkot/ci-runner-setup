#!/usr/bin/env bash
#
# Launch a free, RI-covered GitHub Actions self-hosted runner on EC2 (Graviton).
#
# It mints a short-lived runner registration token, launches an Amazon Linux
# 2023 arm64 instance, and that instance's user-data self-installs + registers
# the runner as a systemd service (survives reboots; reconnects after stop/start).
#
# Self-hosted runners are NOT metered by GitHub, so this sidesteps the Actions
# billing lock entirely, and the compute is covered by the reserved t4g instance.
#
# Prereqs:
#   - gh CLI, authenticated with repo-admin on $REPO  (gh auth status)
#   - aws CLI, creds with ec2:RunInstances/DescribeImages/CreateTags in $REGION
#   - bash (Git-Bash on Windows is fine)
#
# Usage:
#   bash launch-ci-runner.sh
#   REGION=eu-central-1 INSTANCE_TYPE=t4g.small bash launch-ci-runner.sh
#
# After it finishes, set the workflow job to:  runs-on: [self-hosted, Linux, ARM64]
#
set -euo pipefail

# ── config (override via env) ──────────────────────────────────────────────
REPO="${REPO:-Zhivkot/my-consultation-site}"
REGION="${REGION:-eu-central-1}"
# t4g.medium (4 GB) = the whole 2-unit RI; needed if CI ever runs tsc/next build.
# t4g.small (2 GB, 1 unit) is fine for lint + unit tests but OOMs on a full tsc.
INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.medium}"
RUNNER_NAME="${RUNNER_NAME:-gha-ec2-runner}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,arm64}"
NAME_TAG="${NAME_TAG:-gha-runner}"

# Stop Git-Bash from rewriting gh's "repos/..." path args into Windows paths.
export MSYS_NO_PATHCONV=1

# ── preflight ──────────────────────────────────────────────────────────────
command -v gh  >/dev/null || { echo "gh CLI not found"; exit 1; }
command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in — run: gh auth login"; exit 1; }
echo "Repo=$REPO  Region=$REGION  Type=$INSTANCE_TYPE"

# ── 1. mint a short-lived runner registration token ────────────────────────
echo "Minting runner registration token…"
TOKEN=$(gh api -X POST "repos/${REPO}/actions/runners/registration-token" --jq '.token')
[ -n "$TOKEN" ] || { echo "Could not mint token (need repo admin on $REPO)"; exit 1; }

# ── 2. resolve the latest Amazon Linux 2023 arm64 AMI ──────────────────────
echo "Resolving AL2023 arm64 AMI…"
AMI=$(aws ec2 describe-images --region "$REGION" --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-arm64" "Name=state,Values=available" \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)
echo "AMI=$AMI"

# ── 3. build user-data (relative path so native aws.exe can read it) ───────
UD="./.runner-userdata.$$.sh"
trap 'rm -f "$UD"' EXIT
cat > "$UD" <<'USERDATA'
#!/bin/bash
set -xe
exec > /var/log/runner-bootstrap.log 2>&1
dnf install -y git libicu tar gzip python3
cd /home/ec2-user
mkdir -p actions-runner && cd actions-runner
VER=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['tag_name'][1:])")
curl -fsSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-arm64-${VER}.tar.gz"
tar xzf runner.tar.gz
chown -R ec2-user:ec2-user /home/ec2-user/actions-runner
sudo -u ec2-user ./config.sh --url https://github.com/__REPO__ --token __TOKEN__ \
  --name __NAME__ --labels __LABELS__ --unattended --replace
./svc.sh install ec2-user
./svc.sh start
echo BOOTSTRAP_DONE
USERDATA
# Fill placeholders ( | delimiter — none of the values contain a pipe ).
sed -i "s|__REPO__|${REPO}|; s|__TOKEN__|${TOKEN}|; s|__NAME__|${RUNNER_NAME}|; s|__LABELS__|${RUNNER_LABELS}|" "$UD"

# ── 4. launch (default VPC/SG: outbound only, no key, no IAM role) ─────────
echo "Launching ${INSTANCE_TYPE}…"
IID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
  --user-data "file://$UD" \
  --query 'Instances[0].InstanceId' --output text)
echo "Instance=$IID"
aws ec2 create-tags --region "$REGION" --resources "$IID" \
  --tags "Key=Name,Value=${NAME_TAG}" Key=purpose,Value=github-actions-ci 2>/dev/null || true

# ── 5. wait for the runner to register with GitHub ─────────────────────────
echo "Waiting for the runner to come online (≈1–3 min)…"
for _ in $(seq 1 24); do
  CNT=$(gh api "repos/${REPO}/actions/runners" --jq '.total_count' 2>/dev/null || echo 0)
  [ "${CNT:-0}" -ge 1 ] && { echo "Runner online ✓"; break; }
  sleep 15
done

echo
echo "Done — instance $IID running in $REGION."
echo "Point the workflow at it:  runs-on: [self-hosted, Linux, ARM64]"
