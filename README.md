# CI runner setup (EC2 self-hosted GitHub Actions runner)

Scripts to stand up / tear down a **self-hosted GitHub Actions runner** on a
Graviton (`t4g`) EC2 instance for `Zhivkot/my-consultation-site`.

Self-hosted runners aren't metered by GitHub, so this gives **free CI** even
under the Actions billing lock, and the compute is covered by the reserved
`t4g.medium` instance (which was otherwise sitting idle).

## Prerequisites

- **gh CLI**, logged in with repo-admin on the repo — `gh auth status`
- **aws CLI**, with creds that can `ec2:RunInstances` / `DescribeImages` /
  `CreateTags` in the region (the `amplify` IAM user already can)
- **bash** (Git-Bash on Windows works)

## Launch

```bash
bash launch-ci-runner.sh
# overrides:
REGION=eu-central-1 INSTANCE_TYPE=t4g.small bash launch-ci-runner.sh
```

Then set the workflow job to use it:

```yaml
runs-on: [self-hosted, Linux, ARM64]
```

The instance's user-data installs deps, downloads the latest arm64 runner, and
registers it as a **systemd service** (auto-starts on boot, reconnects after a
stop/start). No SSH key, no inbound ports, no IAM role — it only dials out.

## Tear down

```bash
bash teardown-ci-runner.sh        # prompts before terminating
```

## Notes

- **Cost** — the RI (`t4g.medium`, no-upfront, ~$0.0166/hr ≈ $12/mo) is billed
  for its 3-year term regardless. One `t4g.medium` 24/7 = the RI's 2 units, so
  it's fully covered (no on-demand charge). Confirm the RI is in the same region.
- **Size** — `t4g.medium` (4 GB) is the default because a full `tsc` / `next
  build` OOMs on `t4g.small` (2 GB). For lint + unit tests only, `t4g.small`
  (1 RI unit, leaves 1 spare) is enough.
- **`tsc` is not in CI** — it needs the generated `amplify_outputs.json`, which
  is gitignored and absent on a clean checkout. It runs in the repo's pre-push
  hook (local) and in the Amplify build instead. CI runs lint + the test suite.
- **Pushing workflow files** — the `gh` OAuth token lacks the `workflow` scope,
  so commits that touch `.github/workflows/**` must be pushed over **SSH**
  (the repo's `origin` push URL is already set to SSH).
- **Don't switch `runs-on` back to `ubuntu-latest`** — that re-hits the
  GitHub-hosted-minutes billing lock.

## Current deployment (2026-06-01)

- Instance: `i-0ecea2a094839c952` (`t4g.medium`, `eu-central-1`, tag `gha-runner`)
- Runner: `gha-ec2-runner` — labels `self-hosted, Linux, ARM64`
