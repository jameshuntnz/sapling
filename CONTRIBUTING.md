# Contributing

Thanks for looking. A few things about this project are unusual enough that
reading them first will save you a wasted afternoon.

## The one thing to know before opening a pull request

**CI runs on a self-hosted Mac, and it will not run your fork's code.**

Sapling builds itself on a node Sapling provisioned, and Sapling refuses any
workflow run whose code came from outside the repository being watched. That
rule has no exception and no override — it is the control that makes running a
public repository defensible at all (see [SECURITY.md](SECURITY.md)). Approving
the run doesn't help: approval releases the job to the queue, where the node
declines it and it waits out GitHub's timeout.

So a pull request from a fork gets no automated signal. What that means in
practice:

- **Run `make check` locally and say so in the pull request.** That is exactly
  what CI runs. Paste the tail of it if the change is non-trivial.
- A maintainer verifies fork changes by pushing the branch to this repository
  and letting CI run there. Expect that step, and expect it to be the slow part.

None of this applies to a branch pushed directly to this repository.

## Getting set up

You need a Mac with Swift 6 and Xcode command line tools. Nothing else — the
formatter and linter are `swift format` from the toolchain.

```bash
make check     # lint, file sizes, build, test — what CI runs
make format    # reformat in place
make test      # the test suite on its own
make help      # everything else
```

The full suite runs in seconds and needs no network, no GitHub token, and no
VMs: the real `GitHubClient` and the real poll loop are driven against a fake
GitHub API in `Tests/SaplingTests/Support/`, over the same HTTP stack.

To exercise the CLI or the menu bar app without a node:

```bash
swift run sapling demo
```

## Conventions the linter enforces

`make check` fails on all of these, so you'll find out either way — but knowing
why they exist makes them less annoying:

- **Conventional commits.** `feat:` bumps the minor version, `fix:` and `perf:`
  the patch, `!` or `BREAKING CHANGE:` the major; `docs:`, `chore:` and `test:`
  publish nothing. This is not decoration — [scripts/next-version.sh](scripts/next-version.sh)
  derives the released version from the log. See [docs/RELEASING.md](docs/RELEASING.md).
- **Every public declaration carries documentation**, enforced by the
  `AllPublicDeclarationsHaveDocumentation` rule. If that feels heavy for a
  type, the real question is usually whether it needs to be `public` — most
  don't cross a module boundary, and `@testable import` means tests reach them
  anyway.
- **No force-unwrapping or force-`try` in `Sources/`.** `Sources/.swift-format`
  is stricter than the root config on purpose. Test code may force-unwrap a
  literal it just built.
- **Files cap at 300 lines**, warning from 250. The cap is a prompt to split
  along a seam that already exists — an extension, a nested type, a separate
  responsibility — not to shuffle code into a `Misc` file.
- **Workflow files are parsed** by [scripts/check-workflows.sh](scripts/check-workflows.sh).
  An invalid workflow fails in zero seconds with no log, which is easy to
  mistake for a flake.

## Tests

Tests mirror the module layout under `Tests/SaplingTests/`. Two rules that came
from real flakes:

- Anything touching `SAPLING_HOME` or `SAPLING_SERVER` belongs in a
  `.serialized` suite. That state is process-wide.
- Test servers bind port 0. Never a fixed port.

## Changes that need a real machine

The unit suite has been green through every bug that mattered on this project.
[AGENTS.md](AGENTS.md) lists the things that look removable and are not, each
of which cost a debugging cycle on hardware. If your change touches VM or
container lifecycle, the pf egress filter, or the `SessionCommand` routing that
wraps every `tart` and `container` call, please say in the pull request whether
you ran it on an actual node — and if you couldn't, say that instead. "Tests
pass" is not evidence for that layer, and pretending otherwise is how this
project has been burned before.

[docs/TESTING.md](docs/TESTING.md) is the manual verification pass, and
`.github/workflows/verify-node.yml` automates most of it against a provisioned
node.

## Where the `§` references point

Comments and docs cite section numbers — `§8`, `§9.5`, `§12`. They refer to the
original private design document the project was built from, which is not in
this repository. They're kept because they mark the decisions that were made
deliberately rather than fallen into; read them as "this was a decision, not an
accident" and take the surrounding prose as the actual explanation.

## Scope

Sapling is deliberately small. Things that are out of scope and will be
declined: Windows support, a user model or multi-tenancy, and any setting that
would let a node run code from outside the repository it watches. The last one
in particular is not a matter of defaults — see [SECURITY.md](SECURITY.md).

[docs/AUTOMATION-GAPS.md](docs/AUTOMATION-GAPS.md) is the honest list of what
is still manual and what closing each gap would take. It is the best place to
find work worth doing.
