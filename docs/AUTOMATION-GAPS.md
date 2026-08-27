# Automation gaps

Everything a human had to do by hand to bring up `mac-mini-01`, why `sapling
install` didn't do it, and what it would take to close each gap.

Written immediately after the first node was provisioned, while the reasons
were still fresh. Nine of these were discovered by things breaking on real
hardware, not by reading the code — the unit suite was green throughout.

**How to use this:** each gap is self-contained. Take one, read the "why it
wasn't automated" before writing code, and check it against §9.5 of the design
doc, which is the spec `sapling install` implements. Several gaps exist because
§9.5 assumed something that turned out to be false on real hardware; those are
marked, and correcting the doc is part of the work.

---

## First, what genuinely cannot be automated

Don't spend effort here. These are Apple constraints, not missing features.

| Step | Why |
|---|---|
| macOS Setup Assistant on first boot | No scriptable path. Needs a display and keyboard — you can't even enable Remote Login without one. |
| `tailscale up` | Interactive browser login. It prints a URL you can open anywhere, which is as close to scripted as it gets. |
| The base image's first login | A fresh Cirrus image only accepts its published password. Anything automating that is handling a credential. |

Everything else below is a real gap.

---

## Gap 1 — Power management is never configured

**Severity: high.** A node that sleeps is a node that silently stops working.

The mini shipped with `sleep 1` (sleeps after one minute idle) and
`autorestart 0` (stays dead after a power cut). Neither is touched by
`sapling install`; both were set by an ad-hoc bootstrap script that no longer
exists in the repo.

```bash
sudo pmset -a sleep 0 displaysleep 0 disksleep 0
sudo pmset -a autorestart 1 womp 1
sudo pmset -a disablesleep 1   # not supported on every model; ignore failure
```

**Suggested work:** a `PowerStep` alongside the others. `check()` reads
`pmset -g custom` and compares; `fix()` applies. Needs root, which the
installer already has. Straightforward — this is the easiest win in the list.

## Gap 2 — Command Line Tools can only be reported, never installed

**Severity: high**, because it blocks Homebrew and therefore everything else.

`PlatformStep` is check-only and tells the operator to run `xcode-select
--install` — which opens a GUI dialog, useless on a headless box. The headless
route exists and works:

```bash
sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
LABEL=$(softwareupdate -l | awk -F'Label: ' '/Label:.*Command Line Tools/{print $2}' | tail -1)
sudo softwareupdate -i "$LABEL"
sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
```

The sentinel file is what makes the CLT packages visible to `softwareupdate`.

**Suggested work:** give `PlatformStep` a `fix()` for the CLT case only. The
architecture and macOS-version checks stay fatal — they genuinely can't be
fixed.

## Gap 3 — Homebrew taps now need explicit trust

**Severity: high**, because it fails the Tart install outright.

Current Homebrew refuses third-party taps until trusted:

```
Warning: Skipping cirruslabs/cli because it is not trusted.
Error: Refusing to load formula cirruslabs/cli/softnet from untrusted tap.
```

`TartStep.fix()` runs `brew install cirruslabs/cli/tart` and fails. It needs
`brew trust cirruslabs/cli` first.

**Note this is a real trust decision**, not boilerplate: trusting a tap lets
its formulae run arbitrary code at install time. Prompt for it in interactive
mode; require `--trust-taps` or similar in `--non-interactive`. Don't do it
silently.

## Gap 4 — Apple's `container` needs a kernel before it will start

**Severity: high.** `container system start` fails on a fresh install with
`No default kernel configured`, then prompts interactively — which hangs a
non-interactive installer.

Non-interactive equivalent:

```bash
container system kernel set --recommended
```

This downloads Apple's recommended Kata Containers kernel.

**Suggested work:** in `ContainerStep.fix()`, run this before
`container system start`. Route it through `SessionCommand` like everything
else (see Gap 11).

Also fix the Homebrew lookup while you're there: `ContainerStep.fix()` searches
`brew search --cask container`, but `container` is a **formula** in
homebrew-core. The cask search matches only the unrelated `container-ps`, so it
falls through to telling the operator to download a `.pkg` by hand when
`brew install container` would have worked. *(Already fixed — kept here as
context for why the code looks the way it does.)*

## Gap 5 — Non-login shells don't get a usable PATH

**Severity: medium.** Cosmetic for the daemon, confusing for everyone else.

`ssh mini 'sapling status'` fails with `command not found` because
`ssh host 'cmd'` runs a non-login shell, which sources `~/.zshenv` but not
`~/.zprofile` — where Homebrew's installer puts its `shellenv`. `/usr/local/bin`
isn't there either.

The daemon is unaffected: its LaunchDaemon plist sets `PATH` explicitly, which
is the right design and should stay.

**Suggested work:** have `sapling install` append to `~/.zshenv` for the owning
user (idempotently, guarded by a marker), covering `/opt/homebrew/bin` and
`/usr/local/bin`. Small, and it removes a papercut every operator hits within
five minutes.

## Gap 6 — Base image preparation is entirely manual

**Severity: high.** This is the largest gap by effort, and the one most likely
to rot.

Everything below was done by hand, per image:

1. Pull the image (~85GB)
2. Boot it headless and wait for SSH
3. `ssh-copy-id` Sapling's VM key — **needs the image's password, unavoidable**
4. **Verify the toolchain matches what your builds need** (see Gap 7)
5. Update the bundled Actions runner (see Gap 8)
6. Disable Spotlight indexing and automatic updates inside the VM
7. Shut down *cleanly* — every job clones this filesystem
8. Rename the candidate over the previous base image

Only step 3 genuinely needs a human.

**Suggested work:** `sapling image prep [--from <oci-ref>]`. It should pull to
a candidate name, boot, stop at step 3 with the exact `ssh-copy-id` line, then
resume on a second invocation once the key works and do 4–8 unattended. Prepping
to a candidate name and swapping only on success matters: a half-prepared image
that has replaced your working one is a bad afternoon.

Two traps found the hard way:

- **`tart ip` answers from a cached DHCP lease even when the VM is stopped.**
  It is not proof of life. Read the `State` column from `tart list` instead,
  and wait for port 22 to actually accept rather than for an address to exist.
- **`ssh 'sudo shutdown -h now'` hangs the client.** The VM dies before sshd
  closes the channel, so the client blocks until TCP gives up — minutes of
  apparent hang after the work is done. Use `-f` and a short `ConnectTimeout`.

## Gap 7 — Nothing checks the image's toolchain against the build's

**Severity: high**, because the failure is baffling.

The first image pulled was Sequoia, which ships Swift 6.1. The repo targets
6.3. `swift-format` reported that as
`The data couldn't be read because it isn't in the correct format` — once per
source file, forty lines, with no mention of versions. It cost an 85GB
re-download.

`scripts/lint.sh` now checks its own toolchain and says what's wrong, but
nothing checks the *image* before you commit to the download.

**Suggested work:** in `sapling image prep`, report the guest's
`swift --version`, `xcodebuild -version` and macOS version before doing any
further work, and let config declare a minimum. The guest's macOS version need
not match the host's; its toolchain has to satisfy your builds.

## Gap 8 — The bundled Actions runner goes stale, and fails opaquely

**Severity: high.** This produced the single worst failure of the bring-up.

The Tahoe image shipped runner 2.334.0. GitHub had deprecated it. The runner
connected, was refused with `cannot receive messages`, and **exited 0** — so
Sapling recorded a green job that had never run. *(The outcome logic is fixed;
GitHub is now authoritative. But the staleness itself is unaddressed.)*

**Suggested work:** two parts.

- `sapling image prep` updates the runner to the latest release as a matter of
  course. It's a `curl` and a `tar` over the existing directory — JIT config
  means there's no per-runner state worth preserving.
- `sapling doctor` warns when the image's runner is behind
  `actions/runner`'s latest release. A node quietly running a
  soon-to-be-deprecated runner is a scheduled outage.

## Gap 9 — Every deploy needs an interactive sudo

**Closed.** `sapling update` asks the daemon to update itself; since the daemon
is already root, no `sudo` is involved. See [RELEASING.md](RELEASING.md).

Two things it opened, both worth doing:

- **Releases are not code-signed.** The daemon verifies a downloaded archive
  against the `SHA256SUMS` published beside it, which catches corruption but
  not a compromised repository — the checksums come from the same place as the
  archive. Signing with a Developer ID and verifying the signature before
  installing would close it.
- **The node builds its own updates.** CI runs on the node, so a compromised
  node would build and then install its compromised release. Acceptable for a
  single-owner private setup; worth knowing before it is one.

### Superseded — kept for context

**Severity: medium.** Friction, not danger — but it shaped the whole session.

`sapling upgrade` writes `/usr/local/bin` and kickstarts the LaunchDaemon, so
it needs root. During bring-up this meant a human pasting a password roughly
ten times.

The operator declined passwordless sudo, which is a legitimate choice. The
narrow version is a scoped rule that grants root for exactly one binary:

```
admin ALL=(root) NOPASSWD: /usr/local/bin/sapling
```

That is *strictly less* than the operator's password grants, and revoking it is
one `rm`. Note the binary must be root-owned for this to be safe — a whitelisted
path that `admin` can overwrite is a root escalation.

**Suggested work:** offer it during `install` as an explicit opt-in, with the
tradeoff stated plainly. Never default to it.

## Gap 10 — Client-side setup is undocumented and manual

**Severity: low**, but it's the first thing a new operator hits.

On the machine you watch from:

- Install Tailscale and join the tailnet — the API is bound to the tailnet
  only, so without this nothing works and the failure looks like the daemon
  being down.
- Write `~/.sapling/client.toml` with the node's address.
- Build and install the menu bar app.

**Suggested work:** `sapling client setup <node>` that writes `client.toml`
and verifies reachability, plus a client section in the README. The app should
also say *"this Mac isn't on the tailnet"* rather than a generic connection
error, since that's the overwhelmingly likely cause.

## Gap 11 — Both providers need a login session (design doc is wrong)

**Severity: architectural.** Read this before touching provider code.

§10 of the design doc specifies a LaunchDaemon so Sapling runs "independent of
any logged-in GUI session". **That is not achievable with these tools.**

- Apple's `container` keeps state under the user's home and runs its apiserver
  in that user's GUI launchd domain. Root gets
  `XPC connection error: Connection invalid`.
- Virtualization.framework can't create a VM host key without a user session's
  keychain. Root gets `VZErrorDomain Code=-9`, *after* the clone succeeds.

The daemon still runs as root — `SessionCommand` bridges into the console
user's session with `launchctl asuser` + `sudo -u`, which needs no password
because the caller is already root. But **automatic login is now load-bearing**:
without a console user, the node cannot run any job at all.

`SessionRoutingTests` enforces that every `tart`/`container` invocation goes
through `SessionCommand`. Don't bypass it — a single direct call produces a
root-owned VM clone, and that surfaces one step later as
`utimes(2): Operation not permitted` from a completely different command.

**Suggested work:** rewrite §10 of the design doc to match reality. `doctor`
should also check that automatic login is enabled and warn loudly if not,
since the consequence is invisible until a job fails.

---

## Known defects, not gaps

Found during bring-up, not yet fixed.

| Defect | Detail |
|---|---|
| ~~Cache proxy gives up permanently~~ | **Fixed.** `CacheProxySupervisor` now watches the bridge table and runs one listener per gateway, starting and stopping them as bridges come and go. It also no longer binds a single arbitrary gateway, which gave one platform a cache and the other an unroutable address. See [NETWORKING.md](NETWORKING.md). |
| ~~`doctor` can't verify pf as non-root~~ | **Fixed.** `StepState.unverified` exists, and the firewall step reports "cannot verify without root" rather than `ok`. `doctor` prints those as `unknown` and does not count them as problems. |
| Mixed log timestamps | Sapling logs UTC (`2026-08-26T11:09:18Z`), Vapor logs local (`2026-08-26T23:09:18+1200`). Same file, two clocks, twelve hours apart. Genuinely confusing when reading a log. |
| No `sapling logs` command | Reading daemon logs means SSH-ing and `tail`-ing a file. The event log is served over the API; the daemon's own log isn't. |
| Build cache goes over the network | Every job runs in a fresh VM with an empty `.build`, so CI restores a 919MB cache from GitHub — 128s, against a 22s incremental build. On a self-hosted node that is absurd: the cache could live on the host and be mounted into the VM with `tart run --dir`, making it a local disk read instead of a download. That needs Sapling to support mounting a directory into job environments, which would also give Linux jobs a shared package cache. Probably the single largest remaining win on build times. |
| Job pickup latency | ~2–3 minutes observed from push to claim, against a 30s poll. Worth measuring: GitHub's `runs?status=queued` may lag, in which case the poll interval isn't the lever it appears to be. |

---

## Suggested order

1. **Gaps 1–5** — small, independent, remove most of the hand-holding from a
   fresh install. Do these first; each is a self-contained `InstallStep`.
2. **Gap 8** (runner staleness) — highest severity-to-effort ratio remaining.
   A stale runner is a scheduled outage, and the check is a version comparison.
3. **Gaps 6 and 7** (`sapling image prep`) — the biggest piece, and worth
   doing properly once 1–5 have established the pattern.
4. **Gap 11's documentation** — cheap, and prevents someone "fixing" the
   `SessionCommand` indirection back out on the reasonable-looking grounds
   that a root daemon shouldn't need it.
5. **Gaps 9, 10, and the defects** — polish.

## Ground rules

- Every step is idempotent: check first, act only on what's missing. §9.5's
  promise is that re-running `install` after a partial failure, a macOS update,
  or a wipe converges rather than erroring.
- Prefer reporting a manual step clearly over half-automating it. The two
  genuinely manual steps print exact instructions and say why; match that.
- Verify against hardware before believing it works. Every gap here comes from
  something that passed tests and failed on the machine.
