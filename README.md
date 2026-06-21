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

## Add runners for more repos (reuse the same box)

`launch-ci-runner.sh` provisions a *new* instance with one runner.
`add-runner.sh` adds **more repos onto the box you already pay for** — each
gets its own runner directory + systemd service, so several coexist on one
host (one job each; they can run in parallel, so mind RAM — see the notes).

It's **laptop-side and fully dynamic** — give it a repo name, nothing is
hard-coded:

```bash
bash add-runner.sh Zhivkot/my-cdk-project
# optional second arg = labels (e.g. a capability label your workflow targets):
bash add-runner.sh Zhivkot/my-cdk-project self-hosted,linux,arm64,cdk
```

It mints the registration token with your local `gh` (reuses your repo-admin
login — no PAT), finds the instance by its `Name=gha-runner` tag, and installs
the runner on the box **over SSM** (no SSH, no inbound ports, no key), then
verifies it came online. Point that repo's workflow at:
`runs-on: [self-hosted, Linux, ARM64]`.

Tunables are all env vars: `REGION`, `NAME_TAG`, `RUNNER_USER`, `RUNNER_NAME`,
`LABELS`, `INSTANCE_ID` (skip the tag lookup).

### One-time: make the box SSM-reachable

The box is deliberately locked down (no inbound, no SSH key, no IAM role), so
`add-runner.sh` reaches it over **SSM**. Enable that once:

```bash
AWS_PROFILE=admin bash enable-ssm.sh   # needs IAM rights; the plain amplify user may not have them
```

`enable-ssm.sh` creates a minimal role (`AmazonSSMManagedInstanceCore`) + an
instance profile and attaches it to the instance. SSM is outbound-only, so the
"no inbound" posture is preserved. Idempotent — safe to re-run. (Alternatives if
you'd rather not use SSM: open inbound 22 + EC2 Instance Connect, or bake
`add-runner.sh`'s steps into `launch-ci-runner.sh` user-data for new boxes.)

### Removing a per-repo runner

In its dir on the box (`/home/ec2-user/runners/<owner>-<repo>/`):
`sudo ./svc.sh stop && sudo ./svc.sh uninstall`, then
`./config.sh remove --token <removal-token>` (mint with
`gh api -X POST repos/<owner>/<repo>/actions/runners/remove-token --jq .token`).

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
