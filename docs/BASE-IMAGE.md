# Building the base macOS VM image

This is the one part of setup that cannot be automated. The first boot of any macOS VM goes through Setup Assistant, and Apple provides no supported way to script past it. Sapling does not pretend otherwise — it gets everything else running unattended and stops here with instructions.

You do this once. After that, every macOS job clones this image, runs, and deletes the clone.

---

## Fastest route: start from a prepared image

Cirrus Labs publishes images with Xcode already installed.

```bash
tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest sapling-macos-base
```

That pulls ~50GB. It arrives with a user `admin` / password `admin` and Remote Login already on, so you only need steps 2 and 3 below.

## From scratch, if you'd rather control what's in it

```bash
tart create --from-ipsw=latest sapling-macos-base
tart run sapling-macos-base
```

Walk through Setup Assistant on the VM's display:

- Create a user named **`admin`** (must match `macos.ssh_username` in your config)
- Skip Apple ID, Siri, analytics, Screen Time
- In the VM: **System Settings → General → Sharing → Remote Login: on**

---

## 1. Boot it

```bash
tart run sapling-macos-base
```

A window opens with the VM's screen. Find its address from another terminal:

```bash
tart ip sapling-macos-base
```

## 2. Authorise Sapling's SSH key

Sapling connects to VMs with a key, not the image's password — a leaked image password shouldn't be enough to reach a running build. `sapling install` generated the key at `~/.sapling/vm_ed25519`.

From the host:

```bash
cat ~/.sapling/vm_ed25519.pub | ssh admin@$(tart ip sapling-macos-base) \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

(You'll be asked for the image's password once — `admin` for the Cirrus images.)

Verify it took:

```bash
ssh -i ~/.sapling/vm_ed25519 -o IdentitiesOnly=yes admin@$(tart ip sapling-macos-base) 'echo ok'
```

## 3. Bake in the Actions runner — strongly recommended

Without this, every macOS job downloads ~200MB before it can start. Sapling will do that for you and log a warning, but it's a bad trade to repeat forever.

Inside the VM (or over SSH):

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)
curl -fsSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-osx-arm64-${VERSION}.tar.gz"
tar xzf runner.tar.gz && rm runner.tar.gz
```

## 4. Bake in whatever else your builds need

There is no cross-job cache for macOS jobs, by design — the VM is destroyed after every run, and nothing survives it. So anything expensive and stable belongs in the image:

```bash
# examples — install what your workflows actually use
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cocoapods swiftlint
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS   # simulator runtimes, if you need them
```

Rebuild the image periodically as these go stale. That's a deliberate, documented chore rather than something Sapling does behind your back.

## 5. Turn off what a build box doesn't need

Inside the VM:

```bash
sudo mdutil -a -i off              # Spotlight indexing
sudo pmset -a sleep 0 displaysleep 0
sudo softwareupdate --schedule off # no surprise updates mid-job
```

## 6. Shut down cleanly

```bash
ssh -i ~/.sapling/vm_ed25519 admin@$(tart ip sapling-macos-base) 'sudo shutdown -h now'
```

Wait for `tart run` to exit. A clean shutdown matters — clones inherit the filesystem state, and an unclean one propagates to every job.

## 7. Confirm

```bash
tart list
sudo sapling install    # the base image step should now read "ok"
```

---

## Refreshing it later

```bash
tart run sapling-macos-base      # boot, update things, shut down cleanly
```

Or start over: `tart delete sapling-macos-base` and repeat. Jobs in flight are unaffected — they run against clones, not the base.

If you want to keep the old one while testing a new one, build it under a different name and point `macos.base_image` in `~/.sapling/config.toml` at it, then `sudo launchctl kickstart -k system/dev.sapling.daemon`.
