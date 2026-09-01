# Sapling

**Run your GitHub Actions on a Mac you own.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Swift 6](https://img.shields.io/badge/swift-6.0-orange.svg)](https://swift.org)
[![Platform: macOS 15+](https://img.shields.io/badge/platform-macOS%2015%2B%20(Apple%20Silicon)-lightgrey.svg)](#requirements)

Sapling turns an Apple Silicon Mac into a self-hosted GitHub Actions runner
that gives every job a **fresh, isolated machine** and throws it away when the
job finishes — a real macOS VM for macOS jobs, a Linux container for Linux
ones. Nothing carries over between builds.

It's written entirely in Swift and ships three pieces: a daemon, a CLI, and a
native menu bar app you can point at the node from wherever you work.

---

## Why you might want it

- **macOS minutes are the expensive ones.** A Mac mini you already own runs
  them for the price of electricity, and an M4 is not slow.
- **Your builds stay off your laptop.** Every job gets its own VM or container,
  built on demand and deleted afterwards. The isolation is the point.
- **Jobs can't reach your network.** Egress is default-deny to private address
  space — a job can talk to the internet and nothing else. Not your LAN, not
  your router, not your tailnet, not the rest of what the Mac hosts.
- **It's yours.** No third-party runner service, no agent phoning somewhere
  else, no queue you don't control.

## What it does

- **macOS jobs** run in a fresh [Tart](https://github.com/cirruslabs/tart) VM
  cloned from a base image, registered as an ephemeral runner, deleted when the
  job ends. The VM *is* the isolation boundary.
- **Linux jobs** run in an Apple `container` — VM-per-container, sub-second
  boot, near-zero idle memory. Chosen over Docker and Colima specifically to
  keep idle RAM low on a 16GB box.
- **Slots are accounted for**, respecting Apple's hard limit of two concurrent
  macOS VMs, and each job gets a memory budget sized from what it has actually
  used before.
- **Caching happens on the host**, through pull-through proxies, so nothing
  job-specific has to survive between runs for builds to stay fast.
- **Monitoring** is a native menu bar app plus a CLI, both thin clients over
  the same REST API.

## What it deliberately doesn't do

- **Fork builds.** A run is only ever executed when its code came from the
  repository being watched. Fork pull requests are refused — on public and
  private repos alike, with no setting to turn it off, because nothing here
  sandboxes against adversarial job code. See [SECURITY.md](SECURITY.md).
- **Multi-tenancy.** Access control is "you're on my tailnet". There is no user
  model.
- **Windows.** Out of scope.

Single-node today, though the control plane and the enrollment endpoint are
already multi-node shaped — adding a second Mac later is configuration rather
than a rewrite.

---

## Requirements

- An Apple Silicon Mac running **macOS 15 or newer**. A headless Mac mini is
  the intended shape; a spare laptop works.
- **Tailscale**, for reaching the node. The API binds to the tailnet and
  nothing wider.
- A **GitHub App** (recommended) or a personal access token.
- Xcode Command Line Tools. Everything else — Tart, Apple's `container`, the
  LaunchDaemon — is installed by `sapling install`.

## Try it before you commit to anything

```bash
swift run sapling demo
```

That runs the control plane against a seeded in-memory database — no GitHub, no
VMs, no containers — so you can click around the CLI and the menu bar app
immediately.

## Set up a node

On the Mac that will run the builds:

```bash
sudo sapling install
```

It checks every dependency, fills in what's missing, and registers a
LaunchDaemon so the node comes back after a reboot. Re-running it is safe and
only redoes what's absent — after a partial failure, a macOS update, or a wipe.

Two steps genuinely cannot be automated and are printed as instructions when
reached: the one-time Tailscale login, and building the base macOS VM image
(Apple's Setup Assistant has no scriptable path).

→ **[docs/INSTALL.md](docs/INSTALL.md)** is the full bring-up from a wiped
machine. **[docs/BASE-IMAGE.md](docs/BASE-IMAGE.md)** covers the VM image.

## Install the menu bar app

On the Mac you actually work from:

```bash
./scripts/build-app.sh
cp -R dist/Sapling.app /Applications/
open /Applications/Sapling.app
```

Then set the daemon address in the app's settings to your node's Tailscale
name.

## Point a workflow at it

Ordinary self-hosted labels:

```yaml
jobs:
  build:
    runs-on: [self-hosted, macos, arm64]

  test:
    runs-on: [self-hosted, linux, arm64]
```

Linux jobs get a bare runner image by default. If your job needs a real
toolchain, commit a Dockerfile to the repository and ask for it by label:

```yaml
runs-on: [self-hosted, linux, arm64, image:android]
```

The node reads `.sapling/images/android/Dockerfile` at your job's own commit
and builds it, keyed on the directory's git tree SHA — so it rebuilds when the
definition changes and only then.

→ **[docs/CONFIGURATION.md](docs/CONFIGURATION.md#repository-defined-images)**
for how images work, including Rosetta for toolchains with no arm64 build.

---

## The CLI

```
sapling install            Bootstrap this Mac. Safe to re-run.
sapling doctor             Read-only health check of every dependency.
sapling upgrade            Replace the installed binary, restart the daemon.
sapling uninstall          Remove the daemon (--purge also removes config and VMs).

sapling serve              Run the control plane and node agent.
sapling demo               Control plane with sample data, for trying the clients.

sapling status             Node health and slot usage.
sapling jobs               List recent and running jobs.
sapling jobs logs <id>     Event log for one job (-f to follow).
sapling nodes              List nodes.
sapling nodes join-token   Generate an enrollment token.
sapling drain              Stop accepting new jobs, wait for running ones.
sapling cordon / uncordon  Pause / resume job acceptance.
sapling restart            Restart the daemon (refuses while jobs are running).

sapling config             Show the configuration the daemon is running with.
sapling config reload      Re-read config.toml without restarting the daemon.
sapling config validate    Parse and check a config file, warnings included.
sapling config edit        Edit in $EDITOR, check it, save it, reload the daemon.

sapling update             Install the newest release (no sudo — the daemon does it).
sapling update --check     Report what's available without installing it.
```

Every command that talks to the API accepts `--server`, and otherwise resolves
in order: `$SAPLING_SERVER`, `~/.sapling/client.toml`, the local daemon's own
config, loopback.

## The REST API

```
GET  /api/v1/status               node health, slot usage
GET  /api/v1/nodes                list nodes
POST /api/v1/nodes/join-token     generate an enrollment token
GET  /api/v1/jobs?status=&limit=  list jobs
GET  /api/v1/jobs/:id             job detail
GET  /api/v1/jobs/:id/logs?after= event log, tailable
GET  /api/v1/jobs/:id/resources   that job's VM or container, against its limits
GET  /api/v1/config               effective config, credentials redacted
POST /api/v1/config/reload        re-read config.toml without a restart
POST /api/v1/drain                stop accepting new jobs
POST /api/v1/cordon               pause acceptance
POST /api/v1/uncordon             resume acceptance
```

There is no auth layer. The API binds to the Tailscale interface only, and
`BindResolver` refuses to fall back to a wider interface if it can't find a
Tailscale address — so tailnet membership is the access control, and it's sound
*because* of the binding.

## Configuration

`~/.sapling/config.toml`, written by `sapling install`, mode 0600. It's
hand-written TOML — there is no `config set`, because the comments explaining
why a node is tuned the way it is are worth more than the convenience.

You can change most of it without stopping the node:

```bash
sapling config reload
```

Fields the daemon reads at the point of use — the repo list, poll interval,
concurrency and memory ceilings, labels, the update channel — apply live.
Anything consumed once at startup is *reported* rather than silently ignored,
and `sapling restart --wait` applies those after the running jobs finish.

→ **[docs/CONFIGURATION.md](docs/CONFIGURATION.md)** is the full reference.

## Running public repositories

Supported, on one condition that cannot be configured away: **a run is only
executed when its code came from the repository being watched.** Fork pull
requests are refused, on every repository, public or private, because Sapling
does not sandbox against adversarial job code.

Two things to know before pointing a node at a public repo:

1. **Turn on "Require approval for all outside collaborators"** in the
   repository's Actions settings. That's the control that matters. Sapling can
   decline a fork's job but can't withdraw it, so without approval required it
   sits queued until GitHub times it out.
2. **The repo's own commits still run unsandboxed.** Push access to a watched
   repository is push access to that Mac. The daemon says so at startup.

→ **[SECURITY.md](SECURITY.md)** has the full threat model, including what is
and isn't worth reporting as a vulnerability.

## Networking

A job may reach the internet and nothing else. The egress filter is a pf anchor
written per job, and a watchdog re-checks it for the whole life of the job
rather than once at the start — Apple's `container` network can die with
containers still attached, and nothing in `container list` or `tart ip` reports
it.

→ **[docs/NETWORKING.md](docs/NETWORKING.md)** for how it's built and what
reproduction ruled out.

## Releasing and updating

Commit messages drive versions: `feat:` bumps the minor, `fix:` and `perf:` the
patch, `!` or `BREAKING CHANGE:` the major, and everything else publishes
nothing.

A **dev** build publishes whenever CI goes green on `main`. Promotion is
deliberate, from **Actions → Release** or by dispatch:

```bash
gh workflow run release.yml -f channel=stable
```

Nodes update themselves:

```bash
sapling update
```

No `sudo` — the daemon already runs as root, so it downloads, verifies against
the published checksum, swaps its own binary and restarts. It refuses while
jobs are running, and keeps the previous binary so a bad update can be undone.

→ **[docs/RELEASING.md](docs/RELEASING.md)** for channels, hotfixes, and
recovery.

---

## Documentation

| | |
|---|---|
| [INSTALL.md](docs/INSTALL.md) | Bringing up a node from a wiped machine |
| [BASE-IMAGE.md](docs/BASE-IMAGE.md) | Building the base macOS VM image |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Every config field, live reload, repository-defined images |
| [NETWORKING.md](docs/NETWORKING.md) | The egress filter, in detail |
| [TESTING.md](docs/TESTING.md) | Verifying a node behaves, phase by phase |
| [RELEASING.md](docs/RELEASING.md) | Versions, channels, and how a node updates |
| [DESIGN.md](docs/DESIGN.md) | Module layout and why things are shaped this way |
| [AUTOMATION-GAPS.md](docs/AUTOMATION-GAPS.md) | What's still manual, and what closing each gap would take |

## Contributing

```bash
make check     # lint, file sizes, build, test — what CI runs
make format    # reformat in place
make app       # assemble dist/Sapling.app
make help      # everything else
```

The test suite needs no network, no GitHub token, and no VMs — the real client
and poll loop are driven against a fake GitHub API over the same HTTP stack.

One thing to know before opening a pull request: **CI runs on a self-hosted Mac
and will not run a fork's code**, by the same rule described above. Run
`make check` locally and say so.

→ **[CONTRIBUTING.md](CONTRIBUTING.md)** for the conventions and what needs
verifying on real hardware.

## License

MIT — see [LICENSE](LICENSE).
