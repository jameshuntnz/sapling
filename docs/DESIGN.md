# Design notes

Why Sapling is shaped the way it is. Read [the README](../README.md) first for
what it does; this is the reasoning underneath it.

Comments throughout the source cite section numbers — `§8`, `§9.5`, `§12`.
They refer to the original private design document the project was built from,
which is not in this repository. They're kept because they mark decisions that
were made deliberately rather than fallen into; read them as "this was a
decision, not an accident" and take the surrounding prose as the explanation.

## Module layout

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

Both clients — the CLI and the menu bar app — talk to the same `/api/v1`
surface, and neither contains orchestration logic. The agent is the only thing
that orchestrates.

Storage-layer records are kept separate from the wire DTOs on purpose: the
database schema and the API contract should be free to drift apart, and a
little conversion boilerplate is cheaper than coupling them.

Single-node today. The control plane, the `nodes` table and the enrollment
endpoint are already multi-node shaped, so adding a second Mac later is
configuration rather than a rewrite.

## Decisions taken up front

Flagged rather than silently resolved, per the design doc's §12.

| Decision | Taken | Why |
|---|---|---|
| PAT vs GitHub App default | **Both implemented; App is the documented default**, PAT is the quick start | 15k req/hr vs 5k, and finer-grained permissions. `sapling install` offers App first. |
| Cache proxy scope | **Go and Cargo on by default**; npm wired but off | npm/pip URL rewriting is fiddlier and nothing needs it yet. |
| Polling vs webhooks | **Polling**, 30s default | Zero infrastructure, works behind NAT with no public endpoint, matches a Tailscale-only node. |

## Decisions that came out of building it

These weren't planned. Each is documented where it bites, and collected here
because they're the ones that surprise people.

- **JIT runner config over registration tokens.** The runner arrives already
  configured, runs one job, and removes itself. One consequence: a JIT runner
  picks up *whichever* queued job matches its labels, not necessarily the one
  that prompted the launch — so job outcomes are reconciled against the GitHub
  API rather than inferred from the runner's exit code. A deprecated runner
  exits 0 having done nothing, and trusting that once reported a green build
  that never ran.

- **Key-based SSH into macOS VMs**, not the base image's password. Adds one
  line to base-image prep, and means a leaked image password isn't enough to
  reach a running build.

- **The daemon runs as root** so it can manage the pf anchor, with `TART_HOME`
  pointed at your user's image library. `sapling install --run-as <user>`
  exists if Virtualization.framework turns out to be unhappy in the system
  launchd domain — see [INSTALL.md](INSTALL.md#if-vms-fail-to-start-under-the-launchdaemon).

- **Linux jobs need a login session on the node.** Apple's `container` stores
  state under the user's home and runs its apiserver in that user's GUI launchd
  domain, so root cannot talk to it directly — it returns `XPC connection
  error: Connection invalid`. Sapling reaches it with `launchctl asuser`, which
  requires a console user to be logged in. This is why the node is set up with
  automatic login, and it is a property of Apple's tool rather than a choice
  Sapling makes. §10 of the design doc assumed the daemon could be wholly
  independent of a GUI session; with `container` in the stack, it cannot be.

- **Egress subnets are declared in config, not discovered.** The host bridge
  only exists *while* a VM runs, so discovery finds nothing at the moment the
  filter is needed. See [NETWORKING.md](NETWORKING.md).

- **The network watchdog runs for the whole job**, not just at the start.
  Apple's `container` network can die with containers still attached, and
  nothing in `container list`, `container system status` or `tart ip` reports
  it — they keep printing addresses on a subnet the host has no interface for.

- **No build cache.** Measured: restoring 919MB costs ~130s and saving it
  ~185s, against a ~140s build. [AUTOMATION-GAPS.md](AUTOMATION-GAPS.md) has
  the version that would actually help.

## Deferred, not rejected

**A browser dashboard.** It needs no daemon changes — same API, add a static
frontend. Nothing about the API design needs revisiting to enable it.
