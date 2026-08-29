# Testing Sapling

An ordered checklist, arranged so each phase only depends on the ones before it. Phase 0 works on your laptop right now; everything from Phase 1 needs the Mac mini provisioned per [INSTALL.md](INSTALL.md).

Phases 4 and 5 are the ones that actually matter for safety and correctness. Don't skip them because the happy path worked.

---

## Phase 0 — Clients, before any node exists

Runs entirely on the Mac you're reading this on. Nothing here touches GitHub, Tart, or `container`.

```bash
swift build
swift test                      # 32 tests, incl. real HTTP round-trips
./.build/debug/sapling demo     # control plane with sample data on :8734
```

In a second terminal:

```bash
./.build/debug/sapling status
./.build/debug/sapling jobs
./.build/debug/sapling jobs logs 8806      # a failed job, with a full event log
./.build/debug/sapling jobs logs 8801 -f   # follow mode
./.build/debug/sapling cordon && ./.build/debug/sapling status
./.build/debug/sapling uncordon
```

Then the menu bar app:

```bash
./scripts/build-app.sh
open dist/Sapling.app
```

Click the leaf in the menu bar. You should see slot pips, running/queued/recent job sections, and a job's event log when you click one. The Pause button in the footer should flip the node's status pill, and `sapling status` in the terminal should agree.

**Expect:** every screen populated, no spinners stuck, Pause/Resume round-tripping through the API.

## Phase 1 — Node bring-up

On the mini, after `sudo sapling install`:

```bash
sapling doctor
```

**Expect:** every line `ok`. Anything `missing` is fixable with another `sudo sapling install`; anything `manual` needs you (Tailscale login, base image).

```bash
sudo launchctl print system/dev.sapling.daemon | head -20
tail -f ~/.sapling/logs/sapling.err.log
```

**Expect:** `state = running`, and a startup log line naming the repos it's watching.

From your laptop:

```bash
sapling status --server mac-mini-01
```

**Expect:** it connects over Tailscale. If it doesn't, check the daemon actually bound the Tailscale address — the startup log says which address and why.

Save it so you don't have to keep typing `--server`:

```bash
mkdir -p ~/.sapling && echo 'server = "mac-mini-01:8734"' > ~/.sapling/client.toml
```

## Phase 2 — First Linux job

Add this to a **private** test repo:

```yaml
# .github/workflows/sapling-smoke.yml
name: sapling smoke
on: [workflow_dispatch, push]

jobs:
  linux:
    runs-on: [self-hosted, linux, arm64]
    steps:
      - run: uname -a
      - run: echo "hello from $(hostname)"
      - uses: actions/checkout@v4
      - run: ls -la
```

Trigger it, then watch:

```bash
sapling jobs
sapling jobs logs <id> -f
```

**Expect:** the job appears as `queued` within one poll interval (30s), moves through `provisioning` → `running` → `completed`, and the event log shows `container_started`, `runner_registered`, then runner output.

**If it never leaves `queued`:** check the labels. A node only accepts a job when its label set is a *superset* of the job's — the same rule GitHub uses. `sapling status` shows what the node is watching; `linux.labels` in the config is what it offers.

## Phase 3 — First macOS job

```yaml
  macos:
    runs-on: [self-hosted, macos, arm64]
    steps:
      - run: sw_vers
      - run: xcodebuild -version
      - uses: actions/checkout@v4
```

```bash
sapling jobs logs <id> -f
```

**Expect:** `vm_cloned` → `vm_booted` (with an IP) → `ssh_connected` → `runner_registered` → runner output → `cleanup_started` → `cleanup_finished`. First run is slow (the clone), later ones are faster.

Then confirm nothing was left behind:

```bash
tart list
```

**Expect:** only `sapling-macos-base`. Any leftover `sapling-*` clone is a teardown bug — the daemon reaps them at startup, but a leak means a macOS slot was held longer than it should have been.

**If `ssh_connected` never arrives:** the base image is missing the key or Remote Login. Re-do steps 2–3 of [BASE-IMAGE.md](BASE-IMAGE.md).

**If the VM never boots under the daemon but boots fine by hand:** see [INSTALL.md — if VMs fail to start under the LaunchDaemon](INSTALL.md#if-vms-fail-to-start-under-the-launchdaemon).

## Phase 4 — Egress filter (do not skip)

This is the property the whole security posture rests on: a job can reach the internet, and nothing else. This Mac also hosts deployment infrastructure, so getting it wrong is expensive.

First, confirm the rules are actually loaded:

```bash
sudo pfctl -a sapling -sr
sudo pfctl -a sapling -t sapling_jobnets -T show
sudo pfctl -a sapling -t sapling_blocked  -T show
```

**Expect:** a `block drop quick` rule, a jobnets table with the VM bridge subnet, and a blocked table containing `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`.

Then prove it from inside a job. Pick a real private address on your LAN — your router, your NAS, another machine — and add:

```yaml
  egress:
    runs-on: [self-hosted, linux, arm64]
    steps:
      - name: internet should work
        run: curl -sS --max-time 10 https://api.github.com/zen

      - name: LAN should NOT be reachable
        run: |
          if curl -sS --max-time 5 http://192.168.1.1 >/dev/null 2>&1; then
            echo "FAIL: reached the LAN from inside a job"
            exit 1
          fi
          echo "ok: LAN unreachable"

      - name: tailnet should NOT be reachable
        run: |
          if curl -sS --max-time 5 http://100.64.0.1 >/dev/null 2>&1; then
            echo "FAIL: reached the tailnet from inside a job"
            exit 1
          fi
          echo "ok: tailnet unreachable"
```

**Expect:** the job passes. If the LAN step succeeds in reaching anything, stop and fix it before pointing real workflows at this machine.

Run the same check for a macOS job — the two providers use different bridges and both need to be covered.

> The pf tables are populated from the bridge interfaces that exist at the time. Those appear when the first VM or container runs, so on a cold-booted machine the filter is applied at first job dispatch, not at daemon start. Re-run this phase after a reboot.

## Phase 5 — Concurrency limits

Apple allows two concurrent macOS VMs. The scheduler must never try for a third.

Trigger three macOS jobs at once:

```yaml
  fan-out:
    strategy:
      matrix:
        shard: [1, 2, 3]
    runs-on: [self-hosted, macos, arm64]
    steps:
      - run: sleep 120
```

```bash
watch -n2 sapling status
```

**Expect:** macOS slots show `2/2` with the third job sitting in `queued` until a slot frees. Never `3/2`.

## Phase 6 — Restart and crash recovery

```bash
sudo launchctl kickstart -k system/dev.sapling.daemon
sapling jobs --status failed -n 5
```

**Expect:** any job that was mid-flight is marked `failed` with reason `daemon restarted while job was running`, and its event log says so. Slots return to `0`. Nothing stays stuck holding a slot forever.

Then the real test:

```bash
sudo reboot
```

Wait, then from your laptop:

```bash
sapling status --server mac-mini-01
```

**Expect:** it answers without anyone logging into the mini. This is the whole point of the LaunchDaemon — if this fails, `sapling doctor` will say the daemon isn't loaded.

## Phase 7 — Cache proxy

```bash
grep "cache proxy" ~/.sapling/logs/sapling.err.log
du -sh ~/.sapling/runner-cache
```

**Expect:** a line saying it's listening on the bridge gateway. It waits for a bridge interface to appear, so on a freshly booted machine it starts after the first job.

Run a Go or Rust job twice and compare dependency-fetch time. The second run should be noticeably faster, and `runner-cache` should have grown.

## Phase 8 — Drain and cordon

```bash
sapling cordon                    # stop accepting
sapling status                    # status: cordoned
# trigger a job — it should stay queued
sapling uncordon                  # it should now start

sapling drain                     # blocks until running jobs finish
```

**Expect:** cordoned nodes still *see* queued jobs (so the UI stays useful) but don't dispatch them.

## Phase 9 — Config reload

The one that has to be checked with a job running, because that is the whole
point of it: a restart would fail the build.

```bash
# start a long job, then, while it runs:
sudo vi ~/.sapling/config.toml    # change poll_interval_seconds and server.port
sapling config show               # both listed, under reload and restart
sapling config reload
sapling status                    # the job is still running
sudo killall -HUP sapling         # same reload, from the node itself
```

**Expect:** the interval change applied, the port change reported as needing a
restart, and the running job untouched. `grep "config:" ~/.sapling/logs/sapling.out.log`
should show one line per applied field.

Then break the file on purpose — an unclosed `[section` — and reload again.
**Expect:** a rejection naming the line, the daemon still serving, and
`sapling status` unchanged. `sapling config edit` should refuse to save the
same edit while telling you where it kept it.

---

## Known rough edges

Worth knowing before you interpret something as a bug.

**A JIT runner picks whichever queued job matches its labels.** GitHub's ephemeral-runner API has no way to bind a runner to a specific job. So Sapling's "claim" is advisory: it launches an environment because job X is queued, but the runner may pick up job Y instead if Y also matches. Outcomes are therefore reconciled against the GitHub API rather than inferred from the runner's exit code. In practice this self-corrects within a poll cycle; the visible symptom is a job whose recorded start time is a little off.

**Poll interval is the floor on latency.** A job won't start sooner than the next poll, 30s by default. Lower it in config if you want, but it costs rate limit for little gain — and it doesn't make builds faster, only starts.

**macOS jobs have no cross-job cache, by design.** The VM is destroyed. If a macOS build is slow because it re-downloads dependencies, that belongs in the base image ([BASE-IMAGE.md](BASE-IMAGE.md) step 4), not in a cache.

**`sapling join` is not implemented.** Deferred until there's a real second node to test against. The control plane, the `nodes` table, and the join-token endpoint are all in place; the agent-only run mode is the missing piece.

**Public repos are refused in spirit, not in code.** The daemon logs a loud warning at startup if a watched repo is public, but it won't stop you. Sapling does not sandbox against adversarial job code.
