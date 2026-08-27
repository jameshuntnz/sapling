# Job networking

How a job environment gets a network, how Sapling decides whether it still has
one, and why every part of that is arranged the way it is.

Read this before changing anything under `Sources/SaplingAgent/Networking`.
All of it comes from measurement on `mac-mini-01`; none of it came from
reading Apple's documentation, which describes none of these failure modes.

---

## The one rule

**The host's bridge table is the truth. Everything a tool says about its own
network is hearsay.**

Measured on the node, at the same instant, during an outage in which no Linux
job could reach GitHub:

| Source | What it said | Was it true |
|---|---|---|
| `container list` | `192.168.64.4/24`, state `running` | no |
| `container system status` | `running` | technically |
| `container network list` | `default 192.168.64.0/24` | no |
| `tart ip` | an address (answers from a cached lease) | not evidence |
| `sapling doctor` | `ok` for pf, `container` and Tart | no |
| `ifconfig` | **no `bridge100` at all** | yes |

A container started in that state came up, was assigned `192.168.64.5`, and
could not resolve DNS. Every status API reported what had been *configured*.
Only the interface list reported what *was*.

So `BridgeTable` is the single place any of this is decided, and the question
every check reduces to is: **does a host interface own the gateway for the
subnet this environment is on?** That is `JobNetwork.reachability`.

## What the hardware actually does

Two tools share vmnet, and this was assumed to be the fault. It is not.

Measured, with a container and a Tart VM running simultaneously, in **both**
start orders:

```
bridge100: 192.168.64.1     <- Apple container's network
bridge101: 192.168.65.1     <- Tart's network
container 192.168.64.2  ->  api.github.com  OK
VM        192.168.65.70 ->  api.github.com  OK
```

They coexist. Containers take `.64`, Tart takes `.65`, each gets its own
bridge, and starting either second does not disturb the other. **Concurrency
across platforms is safe and did not need to be given up.**

The earlier reading — that they fight over one bridge, and the second to start
wins — came from a capture showing `bridge100` carrying Tart's `192.168.65.1`
while a container held `192.168.64.4`. That is the *aftermath*, not the
mechanism: the container's bridge had already died on its own, freeing index
100 for Tart to take. Tart stole nothing.

What kills the container network is still unidentified. What is established:

- It dies while containers are still attached and still running.
- It does not come back on its own, and starting new containers does not
  recreate it — they are handed addresses on the dead subnet.
- `container system stop && container system start` restores it; nothing less
  does.
- A separate symptom, the VM that "never reported an IP address within 300s",
  is **not** this fault. Its hang report shows 259 seconds inside `pwritev` —
  the VM was starved of disk I/O while a container build ran, on a box with
  one SSD. That is a capacity problem, not a network one.

## The design

Four layers, each answering a question the one before it cannot.

### 1. Before the environment — the filter (`NetworkGuard`)

pf anchor, default-deny to private space, re-asserted before every job. Job
subnets are **declared in config, not discovered**, because the bridge only
exists while an environment is running: discovery at the moment the filter is
needed finds nothing. Config may add coverage and may never subtract it —
`sapling install` freezes defaults into `config.toml`, and a stale file once
left macOS VMs unfiltered while the rules read as correct.

### 2. At start — the host check, then the guest check

In that order, and the order is the point.

`JobNetwork.reachability` asks the host: is there a bridge that owns this
address? It costs one `ifconfig`, needs nothing of the guest, and fails
instantly with the cause. Only then does the in-guest `EgressCheck` probe run,
which covers what the host cannot see — DNS, a too-broad pf rule, a proxy.

Reversed, a VM on a dead subnet burns the entire boot timeout on an SSH that
was never going to connect, and the failure reads as a broken base image.

### 3. During the job — the watchdog

`JobNetwork.awaitLoss` races the job for its whole duration and fails it the
moment its gateway has been gone for two consecutive checks.

This layer exists because the one-shot probe was *passing*. The container that
failed on the node proved egress, compiled a Kotlin module, and then stopped
producing step conclusions — its bridge had gone mid-job, and nothing was
watching. GitHub's account of that is "the self-hosted runner lost
communication with the server", which names nothing and arrives ten minutes
late.

Two confirmations, not one: a bridge is genuinely absent for a moment while
vmnet recreates it, and killing a job for that would be its own flake. A
watchdog that cannot determine an address waits forever rather than
concluding anything — it must never be the thing that fails a job.

### 4. After the loss — repair

`ContainerProvider.repairNetwork` recreates the container network, because
that is the only thing that works. It is gated on being the last running
container: a restart stops all of them, and killing a healthy concurrent job
to repair a broken one is not a trade worth making. With `max_concurrent = 1`
it is unconditional.

There is no equivalent for Tart. A VM whose network dies is torn down, and
the next job clones a fresh one.

## The cache proxy

Two rules, both learned the same way.

**The environment resolves its own gateway; the host never guesses.** The host
used to pass `interfaces.first.address` — whichever bridge came up first — as
`GOPROXY` to *both* platforms. Containers are on `.64.x` and VMs on `.65.x`,
so one platform got a cache and the other got a private address it could not
route to, which the egress filter then blocked, correctly. Which platform won
was decided by boot order. `CacheEndpoint` generates shell that reads the
guest's own default route instead — from `/proc/net/route` on Linux (`ip` is
absent from the runner image; its absence was once misread as "no default
route") and from `route -n get default` on macOS.

**It proves the proxy answers before exporting anything.** A `GOPROXY`
pointing at an address nothing listens on is worse than no `GOPROXY`. The
guest fetches `/_sapling/health` first and falls back to fetching directly.

`CacheProxySupervisor` runs one listener per gateway and starts and stops them
as bridges appear and vanish. It binds the gateways rather than `0.0.0.0`
deliberately: the egress filter permits each job exactly one private address,
and binding wider would put the cache on the LAN and the tailnet too.

## Reporting

`sapling doctor` gains `JobNetworkStep`, which compares both tools'
inventories against the bridge table and names any environment holding an
address nothing owns.

It also stops claiming things it cannot know. `pfctl -sr` needs root and the
CLI is not, so the firewall step used to print `ok` — "anchor wired; rules are
written when the first job starts" — whether the rules were loaded, absent, or
unreadable. It said that throughout the outage. There is now an `unverified`
state that says so plainly and does not count as a problem.

## Rules for changing this

- **Never treat a tool's own status as evidence about its network.** Compare
  against `BridgeTable`.
- **Never fail a job on a check that could not run.** `.unknown` is not
  `.orphaned`; an `ifconfig` that did not execute says nothing.
- **Host-side checks before guest-side ones**, always — cheaper, faster, and
  they name the cause.
- **Every `tart`/`container` call goes through `SessionCommand`.** Enforced by
  `SessionRoutingTests`; see AUTOMATION-GAPS Gap 11 for why.
- **Verify against hardware.** Every claim in this document was measured on
  the node. The unit suite was green through every failure it describes.

## Still open

- What tears down the container network in the first place. The design
  survives and repairs it; it does not prevent it.
- Disk I/O contention between a VM clone and a container build, which produces
  boot timeouts that look like network faults.
