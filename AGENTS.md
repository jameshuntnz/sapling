# Working on Sapling

Self-hosted GitHub Actions orchestration for Apple Silicon. Swift 6 throughout.
Runs jobs in ephemeral Tart VMs (macOS) and Apple `container` (Linux).

```bash
make check     # lint, file sizes, build, test — what CI runs
make format    # reformat in place
make app       # build dist/Sapling.app
```

## Conventions

- **Conventional commits.** `feat:` minor, `fix:`/`perf:` patch, `docs:`/`chore:`/`test:` no release. This drives versioning — see [docs/RELEASING.md](docs/RELEASING.md).
- **Every public declaration is documented**, and production code may not force-unwrap or force-try. Both enforced by `swift format lint`; `Sources/.swift-format` is stricter than the root config.
- **Files cap at 300 lines.** Split along an existing seam.
- **Tests mirror the module layout.** Anything touching `SAPLING_HOME` or `SAPLING_SERVER` goes under a `.serialized` suite — that state is process-wide and has flaked twice. Test servers bind port 0, never a fixed one.

## Things that look removable and are not

Each of these cost a debugging cycle on real hardware. The unit suite was green through every one.

- **`SessionCommand` wraps every `tart`/`container` call.** Both need the console user's login session — `container` for its apiserver, Virtualization.framework for VM host keys. A root daemon calling them directly fails in displaced ways (a root-owned clone surfaces later as `utimes: Operation not permitted` from a different command). `SessionRoutingTests` enforces this at the source level. This means automatic login on the node is load-bearing, contradicting §10 of the design doc.
- **Egress subnets are declared in config, not discovered.** The host bridge only exists *while* a VM runs, so discovery finds nothing at the moment the filter is needed. vmnet also allocates incrementally, so Tart and `container` land on different subnets — measured: containers on `bridge100`/`.64`, Tart on `bridge101`/`.65`, coexisting in either start order.
- **The network watchdog runs for the whole job, not just at the start.** Apple's `container` network can die with containers still attached, and nothing in `container list`, `container system status` or `tart ip` reports it — they keep printing addresses on a subnet the host has no interface for. The one-shot egress probe passed on every environment that then failed this way. See [docs/NETWORKING.md](docs/NETWORKING.md).
- **Orphan reaping protects the base image by name and prefix.** `sapling-` matched `sapling-macos-base`, and the daemon deleted its own 80GB image on every start.
- **GitHub decides job outcomes, not the runner's exit code.** A deprecated runner exits 0 having done nothing; trusting that reported a green build that never ran.
- **No build cache.** Measured: restoring 919MB costs ~130s and saving it ~185s, against a ~140s build. See [docs/AUTOMATION-GAPS.md](docs/AUTOMATION-GAPS.md) for the version that would help.

## Layout

`SaplingCore` (models, config, process interop) · `SaplingDB` (GRDB) · `SaplingAgent` (polling, providers, egress filter) · `SaplingAPI` (Vapor control plane) · `SaplingInstall` (bootstrap steps) · `sapling` (CLI) · `SaplingMenuBar` (SwiftUI app).

## Docs

[DESIGN.md](docs/DESIGN.md) · [CONFIGURATION.md](docs/CONFIGURATION.md) · [NETWORKING.md](docs/NETWORKING.md) · [RELEASING.md](docs/RELEASING.md) · [INSTALL.md](docs/INSTALL.md) · [BASE-IMAGE.md](docs/BASE-IMAGE.md) · [TESTING.md](docs/TESTING.md) · [AUTOMATION-GAPS.md](docs/AUTOMATION-GAPS.md) — what's still manual, for whoever picks this up.

Public-facing: [README.md](README.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md). The threat model lives in SECURITY.md; keep it true when the fork policy or the egress filter changes.

Verify against hardware before believing it works. Everything above came from something that passed tests and failed on the machine.
