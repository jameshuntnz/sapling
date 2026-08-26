# Bringing up the Mac mini from a wipe

Written for the actual situation: a Mac mini M4 (16GB / 256GB) that has just been erased, is headless, and will only ever be reached remotely over Tailscale.

Steps 1–3 are macOS setup you do once, at a keyboard or over Screen Sharing. Everything from step 4 on is `sapling install` doing the work.

---

## 1. macOS first boot

Do this with a display and keyboard attached, or via Screen Sharing from another Mac.

1. Complete Setup Assistant. **Create an admin user you'll use for everything** — these docs assume its short name is `admin`; substitute your own throughout.
2. Sign in.

Then, so the machine is usable headless:

```bash
# Never sleep, and come back after a power cut.
sudo pmset -a sleep 0 disablesleep 1 autorestart 1
sudo pmset -a displaysleep 0
```

Enable Remote Login and Screen Sharing:

**System Settings → General → Sharing** → turn on **Remote Login** and **Screen Sharing**.

Enable automatic login:

**System Settings → Users & Groups → Automatically log in as** → `admin`.

This is **required, not a convenience**, for two separate reasons. A reboot has to bring the machine fully back without someone typing a password at a monitor you don't have — and Apple's `container` runs its apiserver in the console user's GUI launchd domain, so Linux jobs simply cannot run when nobody is logged in. Without automatic login, a reboot leaves you with a node that accepts macOS jobs and fails every Linux one.

> Automatic login means the disk is effectively unlocked at boot. That's the right trade for a headless build box on a network you control, and the wrong one for a laptop.

## 2. Tailscale

This has to come first — after this step you can unplug the display.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install tailscale
sudo tailscaled install-system-daemon
tailscale up
```

`tailscale up` prints a URL to open in a browser to authenticate. **This is a genuine one-time manual step** — there is no way to script around it.

Once it's up, note the machine's Tailscale name and confirm you can reach it from your laptop:

```bash
ssh admin@mac-mini-01
```

From here on, everything can be done over SSH.

## 3. Xcode Command Line Tools

```bash
xcode-select --install
```

Complete the GUI installer (it will appear on the attached display, or over Screen Sharing). `sapling install` checks for this and stops with a clear message if it's missing, rather than failing confusingly later.

## 4. Get the `sapling` binary onto the mini

Either build it there:

```bash
git clone <your-sapling-remote> ~/src/sapling
cd ~/src/sapling
swift build -c release
sudo .build/release/sapling install
```

Or build on your laptop and copy the binary across:

```bash
swift build -c release
scp .build/release/sapling admin@mac-mini-01:/tmp/sapling
ssh admin@mac-mini-01 'sudo /tmp/sapling install'
```

Building on the mini is slower the first time but means `sapling upgrade` has a source tree to rebuild from.

## 5. `sudo sapling install`

```bash
sudo sapling install
```

It works through the checklist and only touches what's missing:

| Step | What happens |
|---|---|
| Platform | macOS 26+, Apple Silicon, CLT — fails early and specifically if not |
| Homebrew | installs it if absent |
| Tart | `brew install cirruslabs/cli/tart` |
| Apple `container` | installs if Homebrew carries it, else prints Apple's current install route |
| Tailscale | already done in step 2; verified here |
| Configuration | prompts for repos and GitHub credentials, writes `~/.sapling/config.toml` at 0600 |
| VM SSH key | generates `~/.sapling/vm_ed25519` |
| Egress filter | wires the pf anchor into `/etc/pf.conf` (backs the original up first) |
| Base macOS image | **manual** — prints instructions, see below |
| sapling binary | copies to `/usr/local/bin/sapling` |
| LaunchDaemon | registers `dev.sapling.daemon`, starts on boot |

To script the whole thing instead of answering prompts:

```bash
sudo sapling install \
  --non-interactive \
  --github-app-id 123456 \
  --github-installation-id 7654321 \
  --github-private-key ~/.sapling/github-app.pem \
  --repo acme/widgets \
  --repo acme/gizmos \
  --node-name mac-mini-01
```

**Re-run `sapling install` freely.** Every step checks before it acts, so re-running after a failure, a macOS update, or a re-wipe converges to the same state instead of erroring or duplicating anything.

## 6. GitHub credentials

A GitHub App is recommended (15,000 req/hr, finer-grained permissions). Create one at **Settings → Developer settings → GitHub Apps → New GitHub App**:

- **Repository permissions:**
  - `Actions: Read-only` — finding queued jobs. Sapling never cancels, re-runs, or dispatches anything, so it needs no write here.
  - `Administration: Read & write` — GitHub classifies managing self-hosted runners as repository administration, not Actions. Registering and removing runners both need write.
  - `Metadata: Read-only` — selected automatically; also how the public-repo warning works.
- Generate a private key, download the `.pem`, and put it at `~/.sapling/github-app.pem` on the mini (`chmod 600`)
- Install the App on the repos you want built, and note the **installation ID** from the installation's URL

A PAT is the faster path if you just want to see it work: a classic token with `repo` scope, passed as `--github-token`. 5,000 req/hr, which is fine for one or two repos at a 30s poll.

## 7. Base macOS VM image — the other manual step

`sapling install` prints these when it gets here. Full walkthrough in [BASE-IMAGE.md](BASE-IMAGE.md).

The short version:

```bash
tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest sapling-macos-base
tart run sapling-macos-base
```

Inside the VM: enable Remote Login, paste `~/.sapling/vm_ed25519.pub` into `~/.ssh/authorized_keys`, optionally bake in the actions runner, then shut down cleanly. Re-run `sudo sapling install`.

## 8. Verify

```bash
sapling doctor     # everything should read "ok"
sapling status
```

Then work through [TESTING.md](TESTING.md), which covers the checks that actually matter — especially proving the egress filter works.

---

## Notes and caveats

### If VMs fail to start under the LaunchDaemon

The daemon runs as root by default because managing the pf anchor requires it. `TART_HOME` is pointed at `/Users/admin/.tart` in the plist, so the root daemon uses the same image library you created the base image in.

Virtualization.framework is normally fine in the system launchd domain, but if VM creation fails there while working by hand, that's the cause. Two ways out:

```bash
# Run the daemon as your user instead. The pf egress filter will not apply.
sudo sapling install --run-as admin
```

or leave it as root and disable the pf filter in config (`block_private_ranges = false`) — **only if the node is on an isolated network**, since that gives jobs LAN access. Prefer the first option; note that you lose §8's protection either way, so say so out loud to yourself before choosing it.

### Apple's `container` CLI

That tool is new enough that its flags and distribution route still move. Sapling shells out to it (`container run --rm --name … --entrypoint /bin/bash <image> -c <script>`) rather than reimplementing it, and `sapling doctor` reports whether the binary is present and the system service is up. If a flag has changed under you, it's in `Sources/SaplingAgent/ContainerProvider.swift` in one place.

### Disk

256GB fills faster than you'd expect: each macOS base image is ~50–60GB and every job clones it (APFS clones are cheap, but divergence isn't). Keep one base image, and let the cache proxy's `max_size_gb` cap package caches.

```bash
tart list                    # what images exist
du -sh ~/.sapling/runner-cache
```

### Logs

```bash
tail -f ~/.sapling/logs/sapling.err.log
sudo launchctl print system/dev.sapling.daemon
```
