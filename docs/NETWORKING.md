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

### What kills the container network

Caught in the act, sampling the host every two seconds during a real PR check:

```
11:42:05  bridges=[bridge100:192.168.64.1]   a container, working
11:44:20  bridges=[]                          <- all of them, at once
11:46:54  bridges=[bridge100:192.168.65.1]   the next VM, fresh bridge100
```

11:44:18 and 11:44:19 are `cleanup_started` and `cleanup_finished` for a macOS
VM. **Tearing that VM down destroyed the bridge a running container was
using**, and its job died mid-step after successfully compiling a module.

It is not teardown as such. Measured directly, with a healthy VM and a healthy
container side by side, `tart stop --timeout 30` followed by `tart delete` took
only the VM's own `bridge101` and left the container on `bridge100` reaching
the internet throughout — before, during and after.

The difference is the state of the VM being torn down. The one that did the
damage had failed: its `tart run` had exited seconds after starting, Tart still
reported the VM as `running`, and no bridge for it had ever appeared. Sapling
did not notice for five minutes — see below — and then tore it down blind.

The precise vmnet mechanism remains unidentified, and a `kill -9` on `tart run`
does not reproduce it (that leaves Tart's state `stopped`, not `running`). So
the design does not claim to prevent it. It does three things instead: catches
the failed `tart run` in seconds rather than minutes, so the broken state is
never sat on; checks after every VM teardown whether anything else lost its
network; and repairs the container network when it has.

### The root cause is not known

Say it plainly, because several plausible stories have been wrong already.

**Established:** a VM's `vmenet` interface is sometimes created and never
attached to a bridge, while a container's attaches normally seconds later. The
VM process is alive and healthy throughout; it simply has no network to ask for
an address on. Tearing that VM down then destroys another guest's bridge.

**Not established:** why the attach fails. Something about a node that has been
up for hours, and nothing about concurrency.

Two theories were tested and discarded:

- *"They fight over one bridge."* No. They get one each — `bridge100` for the
  container, `bridge101` for the VM — and coexist in either start order.
- *"Starting them at the same instant races."* No. On a freshly rebooted node,
  a container and a VM started in the same instant both attached within three
  seconds and the VM had an address in nine — three times out of three.

What separates the failures from the successes is **uptime**, not what else is
running. Every failure happened on a node up for hours; a rebooted node runs
the same workload cleanly.

The best remaining candidate is leaked `sudo tart run` wrappers, one per macOS
job — but a node was observed with one leaked wrapper and zero leaked `vmenet`
interfaces, which breaks the obvious version of that story. It is a candidate,
not an answer.

Since it cannot be reproduced on demand, `NetworkDiagnostics` captures the
host's full networking state the moment an attach fails, before teardown
destroys the evidence. It is built to settle two specific hypotheses:
`InternetSharing` wedging (it logs `waiting for
mis_vmnet_interface_attached_callback` and, in the observed failure, never got
it — if so, `launchctl kickstart -k system/com.apple.InternetSharing` is a
seconds-long repair instead of a reboot), and `bootpd` lease exhaustion on a
`/24` after a day of jobs.

### Why the retry matters more than the cause

Because the cause is unknown, the design does not try to prevent the fault. It
makes it cheap:

- A VM gets 90 seconds to report an address, against a measured healthy nine.
- Failing that, the state is captured, the VM is destroyed, and a **fresh one
  is built** — up to three times.
- Only then does the job fail.

This is worth more than any of the theories, because it works whatever the
cause turns out to be. It also removes the collateral damage: the destructive
teardown only happened because a dead VM was allowed to sit for five minutes,
and now it never does.

### Why platforms are not serialised

`node.serialize_platforms` exists and defaults to **off**. It was briefly
defaulted on, and that was wrong: it gives up half the node's throughput to
avoid a fault it does not prevent. The measurements above — three simultaneous
starts, three clean attaches, and a full PR check running both platforms
through a rebooted node — are why.

### The wayfairer/sapling difference



The failure needs a container and a VM running together, and that is exactly
what a wayfairer PR check does — android in a container, ios in a VM, in
parallel. Sapling's own CI is macOS-only, which is why the node looked healthy
whenever it was building itself.

| Job | Container running too? | Result |
|---|---|---|
| wayfairer iOS 22:13 | yes | no IP, 300s timeout |
| wayfairer iOS 22:31 | yes | no IP, 300s timeout |
| wayfairer iOS 15:48 | yes | no IP, 300s timeout |
| sapling check / release | no | success |
| wayfairer iOS 15:56 | no | booted in 8s |

Inspected while it was stuck: `bridge100` had exactly one member, `vmenet6`,
the container. The VM's `vmenet5` had been created and never attached to any
bridge. The VM process itself was alive and healthy the whole time — it simply
had no network to ask for an address on.

This also explains the "fails once, then works on the retry with no
intervention" pattern. The retry does not win a race. The first attempt's
timeout triggers a teardown, that teardown destroys the container's bridge and
kills the Linux job, and the requeued macOS job then runs **alone** and boots
in eight seconds. The node already serialises — by destroying one job and
spending five minutes doing it.

So `node.serialize_platforms` defaults to on. It gives up no concurrency this
node actually has, and it keeps both jobs. Turn it off to test whether
concurrency has started working, on a node with no leaked `tart run`
processes.

### The leak underneath it

`tart run` is launched as `launchctl asuser … sudo -u admin … tart run`.
Cancelling the task terminates `ProcessRunner`'s immediate child — `launchctl`
— and the `sudo` and `tart` processes beneath it survive, reparented to PID 1.
Deleting the VM does not touch them.

Found on the node: six leaked wrappers, the oldest a day and nine hours old,
one added by every macOS job, alongside six leaked `vmenet` interfaces. A node
accumulating those appears to stop being able to attach a VM to a bridge at
all, which is the most likely reason a VM and a container coexisted happily in
a hand-run experiment earlier in the day and could not two hours later.

They are root-owned, so only the daemon can clear them — `admin` gets
"operation not permitted". Teardown now kills them by name, and startup reaps
any left by a previous life.

### What is established

- The container network dies while containers are still attached and running.
- It does not come back on its own, and starting new containers does not
  recreate it — they are handed addresses on the dead subnet.
- `container system stop && container system start` restores it; nothing less
  does.
- A normal VM teardown is safe. A teardown of a VM that failed to start is not.
- A separate symptom, the VM that "never reported an IP address within 300s",
  has two distinct causes. One is the above — no `tart run`, so nothing to
  DHCP from. The other is disk: a hang report for one such VM shows 259
  seconds inside `pwritev`, starved of I/O while a container build ran on the
  same single SSD. Neither is a network fault, and the message now says which
  it was by reporting the host's bridges alongside it.

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
that is the only thing that works.

The guard is on **health, not presence**. A restart stops every container, so
another container that is still reachable is a job running fine and must not
be killed to repair someone else's network. One that is already orphaned has
nothing left to lose. Presence alone was the wrong test: when a VM teardown
takes the bridge, every container on it is orphaned at once, and refusing to
repair because one of them exists leaves the node broken for the next job too.
A container whose address cannot be determined counts as live — "we could not
tell" is not grounds for killing someone's job.

`NetworkAftercare.afterVMTeardown` runs this check after every VM teardown,
successful or not, since the failing teardown is the one that did the damage.

There is no equivalent for Tart. A VM whose network dies is torn down, and
the next job clones a fresh one.

### 5. The process that was never watched

`tart run` is launched into a detached task and blocks for the VM's lifetime,
so nothing awaits it. That made every way it can fail invisible: the task's own
errors were swallowed, its exit status discarded, and only stderr read — so a
`tart run` that printed its complaint on stdout and exited said nothing at all.

Measured: the process started at 11:39:18.1 and was gone by 11:39:18.2.
Sapling waited the full five-minute boot timeout, reported "VM never reported
an IP address" — true, and not the cause — and then tore the VM down, which is
what took the container's bridge with it.

`VMBootProcess` collects both streams and the exit status, and `waitForIP`
checks it every pass. A VM whose process has gone fails in seconds, carrying
whatever `tart` actually said.

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

## What reproduction ruled out

28 hand-run trials on a clean node, two guests each, classified by whether a
host bridge owned each guest's address:

| Trial set | Guests | Stagger | Result |
|---|---|---|---|
| 20 | `alpine` + base VM | 0, 1, 2, 3, 5s | 20 PASS |
| 8 | 4GB container with `--rosetta` + 6GB VM | 0, 2s | 8 PASS |

Zero failures, and zero leaked `vmenet` interfaces or `tart` wrappers across
28 VM create/destroy cycles. So the fault is **not** simultaneity, not stagger,
not guest size, and not memory pressure from the two guests coexisting.

What the harness could not replicate, and what therefore remains suspect:

- the `launchctl asuser … sudo -u admin` launch path the daemon uses, which
  needs root to invoke
- a container doing real work rather than sleeping
- the daemon's own concurrent activity around a job start

The third is why `AnchorWriter` exists. It is not known to be the cause, but it
was a genuine concurrency defect found while looking for one.

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

## Measured timings

A healthy macOS VM, claim to running a job, on this node:

| Phase | Elapsed |
|---|---|
| clone started | 1s |
| clone + boot + DHCP, to `vm_booted` | 8s |
| host bridge check | <1s |
| SSH accepting | +4s |
| egress proven | +1s |
| runner registered and started | +1s |
| GitHub assigns and the job runs | +9s |
| **total** | **23s** |

The 140GB clone is about a second — APFS copy-on-write. Nothing in the boot
path is slow; the five-minute failures were all a broken `tart run` nobody was
watching.

## Still open

- The vmnet mechanism by which tearing down a failed VM destroys another
  network's bridge. The design detects and repairs it; it does not prevent it,
  and a reproduction outside a real job has not been found.
- Disk I/O contention between a 140GB VM clone and a container build on one
  SSD, which produces boot timeouts that look like network faults.
- **The root cause.** Why a VM's interface fails to attach on a node that has
  been up for hours. `NetworkDiagnostics` exists to answer this the next time
  it happens; until then the retry makes it survivable rather than fatal.
- Whether the leaked `tart run` wrappers are that cause, or merely another
  symptom of the same thing.
