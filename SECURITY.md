# Security

Sapling runs other people's build jobs on a Mac you own. Most of what follows
is about where the trust boundary is, because the answer is narrower than
people expect and knowing it is the difference between a safe deployment and a
compromised laptop-adjacent machine.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: **Security → Report a
vulnerability** on this repository. That opens a private advisory only the
maintainers can see. Please don't open a public issue for anything that looks
exploitable.

Include what you'd want if you were on the other end: the version
(`sapling --version`), the platform involved (macOS VM or Linux container),
what you did, and what happened that shouldn't have.

There is no bounty and no SLA. This is a single-maintainer project; expect a
first reply in days, not hours.

## Supported versions

The newest `stable` release only. There are no backported fixes for older
tags — nodes update themselves in place (`sapling update`), so the remedy for
any released vulnerability is to move forward. `rc` and `dev` builds are
prereleases and get fixes only by being rebuilt from `main`.

## The threat model, stated plainly

**Sapling does not sandbox against adversarial job code.** Jobs run in
ephemeral Tart VMs and Apple `container` instances, which isolate a job from
the host filesystem and from the other jobs beside it, but the project makes no
claim to withstand someone actively trying to break out. The isolation is there
so a build can't corrupt the machine by accident, not so a stranger can't
compromise it on purpose.

Everything below follows from that.

### Not vulnerabilities — these are the documented design

Reports of the following will be closed with a pointer back here. They are
consequences of the model, not defects in it:

- **Push access to a watched repository is code execution on the node.** A
  workflow is a script the node runs. There is nothing between a commit on a
  watched repo and a shell on that Mac, and no setting that would put something
  there. Watch only repositories whose write access you'd grant to the machine
  itself.
- **A repository's `.sapling/images` Dockerfiles execute on the node**, at image
  build time, outside any container, as the daemon. Same trust as running a
  job, granted a little more widely. `build_images = false` declines it.
- **The control-plane API has no authentication.** It binds to the Tailscale
  interface and nothing else, and `BindResolver` refuses to fall back to a
  wider interface when it can't find a Tailscale address. Tailnet membership
  *is* the access control. Reachability of the API from inside your own tailnet
  is the design working, not a finding.
- **The API can change some things on the node**: stop and retry jobs, edit
  live-reloadable config keys (`PUT /api/v1/config`), and delete unused VMs,
  images and old logs (`POST /api/v1/disk/cleanup`). Each is bounded so that
  tailnet access does not become control of what the node trusts. Config
  writes are limited to an allowlist that excludes `update.repository`,
  `github.allow_public_repos`, `build_cache.enabled`, `linux.default_image`,
  every credential and every restart-only key; `github.repos` may only shrink,
  never to empty. A forced update reinstalls but never downgrades. Requests
  carrying an `Origin` header, or a `Host` that isn't an address, `localhost`,
  a single-label or MagicDNS name, are refused, so a web page cannot drive the
  API from a tailnet member's browser.
  Disk cleanup re-checks its target against a fresh listing and refuses the
  base image, job clones and anything running.
- **With `[build_cache]` on, jobs of one repository share build output.**
  Every macOS job reads what the last successful default-branch run of the same
  job left behind, through a directory mounted into its VM. That is shared state
  between jobs, deliberately. It is bounded so it is never *more* trust than
  already exists: only a job that succeeded on the default branch, on the
  runner Sapling started for it, can write what later jobs read. A pull
  request's job reads its base's output and its own writes are thrown away, so
  no branch can put something into a release build that the default branch
  didn't. Jobs in different repositories never share a directory. Off by
  default.
- **The daemon runs as root**, because managing the pf anchor requires it.
- **A refused fork job stays queued on GitHub** until GitHub's own timeout,
  or until a runner Sapling started for another job picks it up — a JIT
  runner takes any queued job its labels match, and GitHub offers no way to
  tie one to a job. The job-started hook every runner is given fails such a
  job before its first step, so it shows as failed rather than queued.
  Sapling cannot withdraw it sooner: GitHub has no per-job cancel, and
  cancelling the run would take down the GitHub-hosted jobs beside it in a
  contributor's pull request.
- **The node's console user is root-equivalent.** Every `tart` and
  `container` call runs in that user's session, and the daemon reads its
  configuration from that user's `~/.sapling`. Anything that runs as that
  user can change what the root daemon does. Treat the account like root.

### In scope — these are vulnerabilities

- A workflow run whose code came from **outside the watched repository** being
  admitted and run. Fork refusal (`ForkPolicy`) is the load-bearing control for
  public repositories, and any way around it is the highest-severity report
  this project can receive.
- A job reaching **private address space** — your LAN, your router, your
  tailnet, or the control plane on the host — past the pf egress filter. Egress
  is default-deny to private ranges; a bypass is a real finding.
- A job **escaping its VM or container** onto the host, or reaching another
  job's environment.
- A job's output reaching the **build cache** read by other jobs when it ran
  on anything but the repository's default branch, or reaching another
  repository's cache at all.
- **Credential disclosure**: the GitHub App private key, a PAT, or a JIT runner
  token appearing in logs, in the API's config response, in an error message,
  or anywhere readable from inside a job.
- Anything that lets a **fork pull request** influence what the node does —
  including via `pull_request_target`, `workflow_run`, or `issue_comment`
  triggers.
- **Update-channel attacks**: getting a node to install an artifact that isn't
  the one the release published, or downgrading it past its channel rules.

## Running a public repository safely

Sapling supports public repositories on one condition that cannot be
configured away: a run is admitted only when its `head_repository.full_name`
matches the repository being watched. Fork pull requests are refused on every
repository, public or private.

That check runs twice. On the host it decides which jobs get a runner. Inside
the guest, a job-started hook reads the job's event payload before any step
and fails the job unless every repository it names as the code's origin
(`pull_request.head.repo`, `workflow_run.head_repository`) is the watched one.
It also refuses `issue_comment` on a pull request, which anyone can trigger.
The second check exists because the first cannot stop a runner from taking a
different job than the one it was started for.

That closes the path that made public repos dangerous. It closes nothing else,
so do both of these as well:

1. **Enable "Require approval for all outside collaborators"** in the
   repository's Actions settings. This is the control that matters — it stops a
   fork's job reaching the queue at all, rather than leaving it queued for a
   node that will decline it.
2. **Treat push access as machine access.** Review who has it with that in
   mind.

See [Running public repositories](README.md#running-public-repositories) for the full
reasoning, and [docs/NETWORKING.md](docs/NETWORKING.md) for the egress filter.
