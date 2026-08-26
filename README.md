# Sapling

Self-hosted GitHub Actions orchestration for Apple Silicon Macs, written entirely in Swift.

Sapling runs ephemeral, isolated build environments — real macOS VMs via [Tart](https://github.com/cirruslabs/tart), Linux containers via Apple's `container` — for GitHub Actions jobs on a Mac you own. It ships a control-plane API, a CLI, and a native menu bar app you can point at the node from wherever you're working.

Single-node today. The control plane, the `nodes` table, and the enrollment endpoint are already multi-node shaped, so adding a second Mac later is configuration, not a rewrite.

---

## What it does

- **macOS jobs** run in a fresh Tart VM cloned from a base image, registered as an ephemeral runner, and deleted when the job ends. The VM *is* the isolation boundary.
- **Linux jobs** run in an Apple `container` — VM-per-container, sub-second boot, near-zero idle memory. Chosen over Docker/Colima specifically to keep idle RAM low on a 16GB box.
- **Slot accounting** respects Apple's hard limit of two concurrent macOS VMs. The config value is advisory; the scheduler always uses the clamped one.
- **Egress is default-deny to private address space.** A job can reach the internet and nothing else — not your LAN, not your router, not your tailnet, not the rest of what this Mac hosts.
- **Caching happens on the host**, through pull-through proxies, so nothing job-specific has to survive between runs for builds to stay fast.
- **Monitoring** is a native menu bar app over Tailscale, plus a CLI. Both are thin clients against the same REST API; neither contains orchestration logic.

## What it explicitly does not do

- **Public repos.** Sapling assumes trusted job code. A public repo can be made to run fork-PR code, which breaks that assumption — the daemon logs a loud warning at startup if you point it at one. Private repos only.
- **Multi-tenancy.** Access control is "you're on my tailnet." There is no user model.
- **Windows.** Out of scope.

---

## Layout

```
Sources/
  SaplingCore/        Shared by every other module
    Models/             Domain types and the API's wire DTOs
    Configuration/      config.toml, one file per section
    Networking/         REST client, endpoint resolution, client config
    System/             Process interop, paths, logging
  SaplingDB/          SQLite (GRDB)
    Schema/             Migrations
    Records/            Storage-layer row types
    Store/              Query surface, split by table
  SaplingAgent/       The only module that orchestrates anything
    GitHub/             API client, App auth, response models
    Providers/          Tart (macOS) and container (Linux) job execution
    Networking/         pf egress filter
    Node/               Poll loop, dispatch, execution, housekeeping
  SaplingAPI/         Control plane
    Server/             Vapor app, routes, bind resolution
    Cache/              Pull-through package caches
  SaplingInstall/     Bootstrap
    Steps/              One file per §9.5 step
  sapling/            CLI (Swift Argument Parser)
    Commands/
  SaplingMenuBar/     SwiftUI MenuBarExtra app
    Model/ Views/ Design/

Tests/SaplingTests/   Mirrors the module layout
  Support/            Shared fixtures, including a fake GitHub API
  Core/ DB/ Agent/ API/ Install/
```

Both clients talk to the same `/api/v1` surface. The agent is the only thing that orchestrates.

Storage-layer records are kept separate from the wire DTOs on purpose: the database schema and the API contract should be free to drift apart, and a little conversion boilerplate is cheaper than coupling them.

---

## Quick start

**On the node** (a Mac mini, headless, reachable over Tailscale):

```bash
sudo sapling install
```

It checks every dependency and fills in what's missing, then registers a LaunchDaemon so it comes back after a reboot. Re-running it is safe and only redoes what's absent — after a partial failure, a macOS update, or a wipe.

Two steps genuinely cannot be automated and are printed as instructions when reached: the one-time Tailscale login, and building the base macOS VM image (Apple's Setup Assistant has no scriptable path). See [docs/INSTALL.md](docs/INSTALL.md) for the full bring-up from a wiped machine.

**On the Mac you work from:**

```bash
./scripts/build-app.sh
cp -R dist/Sapling.app /Applications/
open /Applications/Sapling.app
```

Set the daemon address in the app's settings to your node's Tailscale name.

**Trying it out before a node exists:**

```bash
sapling demo
```

Runs the control plane against a seeded in-memory database — no GitHub, no VMs, no containers — so you can exercise the CLI and the menu bar app immediately.

---

## CLI

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
```

Every command that talks to the API accepts `--server`, and otherwise resolves in order: `$SAPLING_SERVER`, `~/.sapling/client.toml`, the local daemon's own config, loopback.

---

## REST API

```
GET  /api/v1/status               node health, slot usage
GET  /api/v1/nodes                list nodes
POST /api/v1/nodes/join-token     generate an enrollment token
GET  /api/v1/jobs?status=&limit=  list jobs
GET  /api/v1/jobs/:id             job detail
GET  /api/v1/jobs/:id/logs?after= event log, tailable
POST /api/v1/drain                stop accepting new jobs
POST /api/v1/cordon               pause acceptance
POST /api/v1/uncordon             resume acceptance
```

Bound to the Tailscale interface only. There is no auth layer — tailnet membership is the access control, which is sound *because* of the binding, so `BindResolver` refuses to fall back to a wider interface if it can't find a Tailscale address.

**A browser dashboard was deferred, not rejected.** It needs no daemon changes — same API, add a static frontend. Nothing about the API design needs revisiting to enable it.

---

## Configuration

`~/.sapling/config.toml`, written by `sapling install`, mode 0600.

```toml
[node]
name = "mac-mini-01"

[server]
bind = "tailscale"   # or "loopback", or an explicit address
port = 8734

[github]
auth = "app"         # "app" (recommended) or "pat"
app_id = "123456"
installation_id = "7654321"
private_key_path = "~/.sapling/github-app.pem"
repos = ["acme/widgets"]
poll_interval_seconds = 30

[macos]
enabled = true
base_image = "sapling-macos-base"
max_concurrent = 2   # clamped to 2 — Apple's limit
ssh_username = "admin"

[linux]
enabled = true
default_image = "ghcr.io/actions/actions-runner:latest"
max_concurrent = 2

[network]
block_private_ranges = true    # §8 — leave this on
allowed_cidrs = []             # escape hatch for a specific host

[cache]
enabled = true
port = 8735
proxies = ["go", "cargo"]
```

---

## Open decisions

Flagged rather than silently resolved, per the design doc's §12.

| Decision | Taken | Why |
|---|---|---|
| PAT vs GitHub App default | **Both implemented; App is the documented default**, PAT is the quick start | 15k req/hr vs 5k, and finer-grained permissions. `sapling install` offers App first. |
| Cache proxy scope | **Go and Cargo on by default**; npm wired but off | Follows ephemerd's precedent. npm/pip URL rewriting is fiddlier and nothing needs it yet. |
| Polling vs webhooks | **Polling**, 30s default | Zero infrastructure, works behind NAT with no public endpoint, matches a Tailscale-only node. |

Three more decisions came up during implementation and are documented where they bite:

- **JIT runner config over registration tokens.** The runner arrives already configured, runs one job, removes itself. One consequence: a JIT runner picks up *whichever* queued job matches its labels, not necessarily the one that prompted the launch — so job outcomes are reconciled against the GitHub API rather than inferred from the runner's exit code.
- **Key-based SSH into macOS VMs**, not the base image's password. Adds one line to base-image prep; means a leaked image password isn't enough to reach a running build.
- **The daemon runs as root** so it can manage the pf anchor, with `TART_HOME` pointed at your user's image library. `sapling install --run-as <user>` exists if Virtualization.framework turns out to be unhappy in the system launchd domain — see [docs/INSTALL.md](docs/INSTALL.md#if-vms-fail-to-start-under-the-launchdaemon).

---

## Development

```bash
make check     # lint, file sizes, build, test — what CI runs
make test      # 141 tests
make format    # reformat in place
make app       # assemble dist/Sapling.app
```

`make help` lists everything.

### Code hygiene

Formatting and linting use `swift format` from the toolchain, so there is nothing to install.

- **`.swift-format`** is the baseline. `Sources/.swift-format` adds the stricter rules production code is held to — no force-unwrapping, no force-`try`. Test code may reasonably force-unwrap a literal it just built.
- **Every public declaration carries documentation**, enforced by `AllPublicDeclarationsHaveDocumentation`. If that feels heavy for a given type, the question to ask is whether it needs to be `public` at all — most types don't cross a module boundary, and `@testable import` means tests can still reach them.
- **Files are capped at 300 lines** (`scripts/check-file-sizes.sh`, warning from 250). The cap is a prompt to split along a seam that already exists — an extension, a nested type, a separate responsibility.

Tests mirror the module layout and share fixtures from `Tests/SaplingTests/Support/`, including a fake GitHub API that the real `GitHubClient` and the real poll loop are driven against — same HTTP stack, same JSON shapes, no network and no token.
