# Releasing and updating

How a change gets from a commit to a running node.

Two halves that meet at a GitHub Release: the **release pipeline** builds and
publishes; the **node updates itself** from what was published. Neither needs
`sudo`, and neither needs you to touch the mini.

---

## Commit messages decide the version

Conventional commits, read by `scripts/next-version.sh`:

| Prefix | Bump | Example |
|---|---|---|
| `feat:` | minor | `feat: show node metrics in the menu bar` |
| `fix:` `perf:` | patch | `fix: stop the daemon deleting its base image` |
| `feat!:` or `BREAKING CHANGE:` in the body | major | see the 0.x note below |
| `docs:` `test:` `chore:` `refactor:` `ci:` `style:` | **none** | a release with only these publishes nothing |

Scopes are fine: `fix(agent): …` counts the same as `fix: …`.

**While the version is 0.x, a breaking change bumps the minor**, not to 1.0.
Reaching 1.0 should be a decision someone makes, not something a commit message
does by accident.

`scripts/test-next-version.sh` exercises this against throwaway repositories,
and runs in CI.

## Channels

A version says which channel it belongs to, so nothing has to be tracked
separately:

| Channel | Looks like | Cut from |
|---|---|---|
| `dev` | `0.2.0-dev.7+a1b2c3d` | main, whenever you want a build |
| `rc` | `0.2.0-rc.1` | main, when a version looks ready |
| `stable` | `0.2.0` | a candidate you're happy with |
| `hotfix` | `0.1.1` | a release branch, to ship a fix without dragging in main |

Ordering follows semver, which matters more than it looks:

```
0.2.0-dev.7  <  0.2.0-rc.1  <  0.2.0  <  0.2.1-dev.1
```

A prerelease precedes the release it leads to. So a node on `0.2.0` will not
take `0.2.0-dev.9` — correctly, that build is *older*. `SemanticVersionTests`
covers this against the spec's own worked example.

## Cutting a release

**A dev build publishes for every commit that reaches `main` green.** Release
is triggered by CI succeeding, not by the push — which is what makes it cheap
enough to do every time:

- CI has just run lint, sizes, workflows, version derivation and the full test
  suite on that exact commit, so the release skips its own Verify. That was
  158s of a 306s release, so the automatic path costs about 145s.
- CI cancels in progress, so a burst of pushes leaves one surviving CI run and
  therefore one release. Release *cannot* cancel in progress — interrupting it
  between tagging and publishing would leave a tag with no release — so
  triggering on push would have queued a build per commit.

A red or cancelled CI run publishes nothing: `workflow_run` fires on every
completion, so the release checks the conclusion.

Promotion to **rc** and **stable** stays deliberate, and a deliberate run
always verifies — it may be aimed at a commit CI never saw.

**Actions → Release → Run workflow**, and pick a channel. Or:

```bash
gh workflow run release.yml -f channel=stable
```

The pipeline then:

1. **Works out the version** from commits since the last tag. If nothing
   warrants a release it stops here and says so.
2. **Verifies** — workflows, lint, file sizes, version derivation, the full
   test suite. Nothing is published that hasn't passed its own checks.
3. **Stamps the version** into `SaplingVersion.current`.
4. **Builds and packages** `sapling-<version>-macos-arm64.tar.gz` plus
   `SHA256SUMS`.
5. **Tags**, and for a stable release commits the version stamp to `main`.
6. **Publishes** the GitHub Release, marked prerelease for anything but
   stable and hotfix.

It runs on the node itself, so Sapling builds and releases Sapling.

**Tags carry no build metadata.** A dev version is `0.2.0-dev.7+a1b2c3d`, but
its tag is `v0.2.0-dev.7`. `+` is literal in a URL path and a space in a query
string — a good way to lose a release. Semver ignores build metadata for
precedence, so nothing that matters is lost, and the binary still reports the
commit it came from.

---

## How a node updates

```toml
[update]
repository = "jameshuntnz/sapling"
channel = "dev"              # dev | rc | stable
check_interval_hours = 6
auto_apply = false
```

A node on `dev` accepts rc and stable builds too — they are further along the
same line. A node on `stable` takes only finished releases.

### Updating

```bash
sapling update --check     # what's available
sapling update             # install it
```

**No `sudo`.** The daemon already runs as root, so it does the work itself:
the CLI is only asking. That is the whole reason updating stopped being a
chore.

What the daemon does, in order:

1. **Refuses if jobs are running** — a restart marks every in-flight job failed
   and reaps its VM. `--force` overrides.
2. **Downloads** the archive and `SHA256SUMS` from the release.
3. **Verifies** the archive against the published checksum. A mismatch stops
   here.
4. **Unpacks** and checks there is a runnable binary inside.
5. **Swaps the binary**, moving the old one to
   `/usr/local/bin/sapling.previous` rather than overwriting it — writing over
   a running executable gives you `Text file busy`. If the copy fails, the old
   binary is moved back, so a failed update leaves a node that still starts.
6. **Restarts** via `launchctl kickstart`.

The CLI then waits for the daemon to come back and reports the version it is
actually running — worth doing rather than assuming, because a failed restart
leaves the node down and you should hear that from the tool rather than from a
job that never ran.

### When it says "up to date" and you disagree

Almost always semver being right. Check what the node thinks it is:

```bash
sapling update --check
```

If the running version *outranks* everything published — a locally built
binary, or a version stamp that got ahead — then nothing published is an
upgrade, and that is the correct answer to the question asked. To install the
newest release anyway:

```bash
sapling update --force
```

The development placeholder is `0.0.0-dev` precisely so this doesn't happen: a
locally built binary sorts below every release. It was `0.1.0` once, which is a
*stable* version, and a node running it refused every `0.1.0-dev.N` release as
a downgrade.

### Recovering a bad update

The previous binary is kept:

```bash
ssh -t <node> 'sudo /usr/local/bin/sapling.previous upgrade --binary /usr/local/bin/sapling.previous'
```

That reinstalls the old version and restarts. `sapling doctor` afterwards.

---

## Which workflow runs when

| Event | Workflow | Publishes |
|---|---|---|
| push to `main` | CI — workflows, lint, sizes, version derivation, build, test | no |
| **CI succeeds on `main`** | Release, on the `dev` channel | **yes** |
| pull request | CI | no |
| **Actions → Release** | Release — verify, build, tag, publish | **yes** |
| Actions → Verify node | the hardware checks in [TESTING.md](TESTING.md) | no |

CI and Release deliberately never run together. They did once, on every push,
and since each boots a macOS VM and there are only two slots, every push queued
behind itself for the better part of ten minutes.

**There is no build cache, on purpose.** It was measured and made things worse:
restoring 919MB costs ~130s and *saving* it ~185s, against a full build of
~140s. See [AUTOMATION-GAPS.md](AUTOMATION-GAPS.md) for the version of this
that would actually help — a cache on the host, mounted into the VM, rather
than one crossing the network.

## Release checklist

For anything reaching a node you care about:

- [ ] `make check` passes locally
- [ ] CI green on `main`
- [ ] Dispatch **rc** first if the change touches provisioning, the egress
      filter, or the update path itself — those fail in ways that are hard to
      see from the outside
- [ ] Point a node at `rc`, or `sapling update` one you can afford to break
- [ ] Run **Verify node** ([TESTING.md](TESTING.md) phases 2–5), especially the
      egress checks
- [ ] Dispatch **stable**

The egress test is the one worth the extra minutes. It has caught the filter
silently doing nothing twice, and both times everything else looked healthy.
