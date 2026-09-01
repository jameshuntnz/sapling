# Configuration

`~/.sapling/config.toml`, written by `sapling install`, mode 0600.

Every field is listed below with its default. You only need the sections you
actually want to change.

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
repos = []           # empty: every private repo the App installation grants
poll_interval_seconds = 30
# After 3 failed attempts the node gives up on a job. GitHub has no per-job
# cancel, so telling it means cancelling the whole run — siblings included.
cancel_run_when_exhausted = false
# Let discovery watch public repos too. Fork PRs are refused either way.
allow_public_repos = false

[macos]
enabled = true
base_image = "sapling-macos-base"
max_concurrent = 2   # clamped to 2 — Apple's limit
ssh_username = "admin"

[linux]
enabled = true
default_image = "ghcr.io/actions/actions-runner:latest"  # used when a job names none
max_concurrent = 2
rosetta = false                   # translate x86-64 binaries — Android's aapt2 needs it
                                  # requires Rosetta on the host: see below
build_images = true               # build images the repos define (see below)
images_path = ".sapling/images"   # where in each repo those definitions live
# arch = "arm64"                  # only to run a foreign-architecture image outright

[network]
block_private_ranges = true    # leave this on; see NETWORKING.md
allowed_cidrs = []             # escape hatch for a specific host

[cache]
enabled = true
port = 8735
proxies = ["go", "cargo"]

[update]
repository = "jameshuntnz/sapling"
channel = "stable"       # stable | rc | dev
check_interval_hours = 6
auto_apply = false       # even when true, only applies while idle
```

## Changing it without stopping the node

`sapling config reload` re-reads the file into the running daemon; `SIGHUP`
does the same from the node itself. Neither restarts anything, which matters
because a restart fails whatever job is mid-build — up to two hours of it.

Only the fields the daemon reads at the point of use change live: the poll
list and interval, the concurrency and memory ceilings, the labels, the Linux
default image, and the whole `[update]` section. Everything else was consumed
once — the listener is bound, the providers hold their platform settings, the
pf anchor is written — so a reload **reports** those and leaves them alone
rather than letting the file describe something the machine isn't doing.

```
$ sapling config reload
applied 2 fields; 1 field needs a daemon restart

Applied
  github.poll_interval_seconds  30 → 60
  github.repos                  [acme/widgets] → [acme/widgets, acme/gizmos]

Needs a daemon restart
  server.port                   8734 → 9001
```

`sapling restart` applies the rest, and `--wait` lets the running jobs finish
first rather than failing them. No sudo: the daemon is already root, so it
restarts itself.

The file is parsed and validated in full before any of it is applied, so a
typo leaves the node exactly as it was. `sapling config show` says the same
thing ahead of time — what is running, and what is waiting in the file for a
reload or a restart — and `sapling config edit` does the whole loop through a
copy, so an edit that fails to parse is never written back.

There is no `config set`. The file is hand-written TOML whose comments explain
why a node is tuned the way it is, and writing it back from a decoded struct
would throw all of that away.

## Which repositories a node watches

Leave `github.repos` empty and the node watches **every private repository its
GitHub App installation can reach**, so granting access is done once on GitHub
rather than twice. List repositories explicitly to narrow it.

The list is re-checked every 15 minutes, so granting or revoking a repository
takes effect without a restart. If GitHub is unreachable the last known list is
kept — a node that quietly stopped watching everything is indistinguishable
from one with no queued work.

**Public repositories are not discovered this way unless you ask.** They are
logged and skipped until `allow_public_repos = true`; naming one in
`github.repos` takes just that one. Inheriting a repository through an
installation nobody re-read is not a decision, and this keeps it from being
treated as one. It is not the safety boundary, though — fork refusal is, and
that is unconditional. See [SECURITY.md](../SECURITY.md).

Empty is only meaningful under App auth. A PAT has no installation to
enumerate — it reaches every repository its owner can see — so `repos` must be
spelled out, and the daemon refuses to start otherwise.

`sapling status` reports the resolved list, not the configured one.

## Repository-defined images

`ubuntu-latest` is not Ubuntu — it is a GitHub-maintained image preloaded with
five JDKs, the Android SDK, `yq` and much else, and workflows depend on all of
it without ever saying so. Sapling's Linux default is the bare runner agent, so
each repository declares the images its own jobs need:

```
.sapling/images/
  android/Dockerfile
  release-tools/Dockerfile
```

A job asks for one by label. GitHub's REST API does not expose a job's
`container:` key, so labels are the only channel available:

```yaml
runs-on: [self-hosted, linux, arm64, image:android]
```

The node strips `image:*` before deciding eligibility, reads that directory at
the job's own commit, and builds it. **The cache key is the directory's git
tree SHA**, which is what makes this work without a registry: git already
hashes the directory's exact contents, so an image rebuilds when — and only
when — its definition changes, and an ordinary commit to application code is a
cache hit. A job naming no image gets `default_image`.

Images are per-purpose, not per-repo. A repository with a Node client and an
Android app should define two small images rather than one carrying both
toolchains. Images sharing a `FROM` share those layers on disk, so the base is
paid for once.

Unused built images are pruned after 30 days, by reference rather than age — an
image a job still points at is kept however old it is.

Two things worth knowing before enabling this:

- **A repository's Dockerfile executes on the node**, at build time, outside
  the job container. The definition is read at the job's own commit, and only
  commits from the watched repository are ever run, so the trust is the same as
  running a job — granted more widely. `build_images = false` declines it, and
  on a public repository that is worth a second thought: whoever can push can
  run a build step as the daemon.
- **A changed Dockerfile blocks the next job** that asks for it, for as long as
  the build takes. Subsequent jobs hit the cache.

### Rosetta, for toolchains with no arm64 build

Some build tools have no arm64 Linux binary at all. Android's `aapt2` is the
one that bites: Google publishes it for `linux-x86_64` only, and the Gradle
plugin downloads its own copy from Maven regardless of what the SDK holds, so
on an arm64 node it fails with `Exec format error`. A container does not
emulate a CPU, so no image fixes this.

Setting `rosetta = true` exposes Rosetta inside the container, and that one
binary is translated while the JVM, compilers and everything else keep running
natively. The image also has to carry the x86-64 loader and libc
(`libc6:amd64`, `libgcc-s1:amd64` on Debian/Ubuntu).

**Rosetta must be installed on the host**, which a headless Mac that has never
run an Intel binary will not have:

```bash
sudo softwareupdate --install-rosetta --agree-to-license
```

The daemon refuses to start when `rosetta = true` and it is missing, rather
than letting the job fail with an elf loader error that mentions neither.
