# Releasing and updating

Commit messages drive versions, versions drive releases, and nodes pull
releases themselves. Nobody types a version number, and updating a node needs
no `sudo`.

---

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org). The type prefix
decides the version bump, so it is the one part of a message that has to be
mechanical.

```
<type>[optional scope][!]: <subject>

[body]

[BREAKING CHANGE: description]
```

| Type | Bump | Use for |
|---|---|---|
| `feat` | minor | New behaviour |
| `fix` | patch | A defect |
| `perf` | patch | Something measurably faster |
| `refactor` | none | Restructuring with no behaviour change |
| `docs`, `test`, `chore`, `ci`, `build`, `style` | none | Everything else |

A `!` before the colon, or a `BREAKING CHANGE:` paragraph in the body, forces a
major bump.

```
feat(agent): re-offer jobs that failed locally
fix: stop the daemon deleting its own base image
perf(cache): stream release assets instead of buffering
refactor!: rename the job event schema

BREAKING CHANGE: `runs.event` values are now namespaced.
```

**While the version is 0.x, a breaking change bumps the minor** rather than
going to 1.0. Reaching 1.0 should be a decision, not the side effect of a
comment on a commit.

Only `feat`, `fix` and `perf` produce a release. A run of `docs` and `chore`
commits publishes nothing, which is the intent — not every push deserves a
version.

---

## Channels

Three streams, distinguished by the version itself rather than tracked
separately, so a version string always says what it is.

| Channel | Looks like | Published |
|---|---|---|
| `dev` | `0.5.0-dev.12+a1b2c3d` | Automatically, on every push to `main` |
| `rc` | `0.5.0-rc.1` | On request, when a version looks ready |
| `stable` | `0.5.0` | On request, when it is ready |

A node follows one channel and takes anything **at least as finished** as it:
`dev` accepts dev, rc and stable; `stable` accepts only stable. That ordering
is what stops a production node ever installing a development build, and it is
derived from the version, so a release mislabelled in GitHub's UI cannot
override it.

Set it per node:

```toml
[update]
channel = "stable"    # stable | rc | dev
```

## Publishing

**Dev builds** need nothing — every push to `main` with a `feat`, `fix` or
`perf` commit publishes one.

**Release candidates and releases** are deliberate. Run the *Release* workflow
and pick a channel:

```bash
gh workflow run release.yml -f channel=rc
gh workflow run release.yml -f channel=stable
```

Each run verifies before it publishes — lint, file sizes, the version-derivation
tests and the full suite — so a release that does not pass its own checks never
gets a tag.

Only a `stable` release writes the version back into the source. Dev versions
are derived, and committing one per push would both spam `main` and re-trigger
the workflow.

**Hotfixes** patch an existing release without dragging in whatever has landed
on `main` since. Branch from the tag, commit the fix, and publish:

```bash
git checkout -b release/0.4.x v0.4.0
git cherry-pick <the fix>
gh workflow run release.yml --ref release/0.4.x -f channel=hotfix
```

`hotfix` bumps the patch of the last release reachable from that branch and
ignores everything else, so `v0.4.0` becomes `v0.4.1` even if `main` is well
past it.

---

## Updating a node

From anywhere on the tailnet:

```bash
sapling update --check    # report what's available
sapling update            # install it
```

**No `sudo`.** The daemon already runs as root, so the CLI asks *it* to update
itself: it downloads the release, verifies it, replaces its own binary and
restarts. Asking a person to do that means a password prompt for every deploy,
which during the first node bring-up meant about ten of them.

An update is refused while jobs are running, because restarting the daemon
fails every job in flight and reaps its VM. `--force` overrides that when you
mean it.

To let a node update itself:

```toml
[update]
auto_apply = true
check_interval_hours = 6
```

Even then it only applies while the node is idle.

### What the update trusts

The daemon downloads a binary and runs it as root, so the download is the
security boundary. Three things guard it:

- the release is fetched over HTTPS, from the configured repository only
- the archive is checked against the `SHA256SUMS` published beside it
- a release with no checksums is **refused**, not installed unverified

What that does *not* cover: the checksums come from the same place as the
archive, so this catches corruption and interrupted downloads, not a
compromised repository. **Code signing with a Developer ID would close that
gap** and is the obvious next step.

The previous binary is kept at `/usr/local/bin/sapling.previous`, so a bad
update can be backed out by hand.

### Private repository

Sapling's repository is private, so reading releases needs authentication. The
GitHub App needs **`Contents: Read-only`** in addition to the permissions job
polling uses — without it, update checks fail with a 404 that says so.
