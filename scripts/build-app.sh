#!/bin/bash
# Assemble SaplingMenuBar into a real .app bundle.
#
# MenuBarExtra needs a bundle with LSUIElement set, otherwise the app gets a
# Dock icon and a main menu it has no use for. SwiftPM only produces a bare
# executable, so the bundle is assembled here.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Sapling.app"

cd "$ROOT"
echo "Building SaplingMenuBar ($CONFIG)…"
swift build -c "$CONFIG" --product SaplingMenuBar

BIN="$(swift build -c "$CONFIG" --product SaplingMenuBar --show-bin-path)/SaplingMenuBar"
# Located rather than hardcoded, so moving the file doesn't silently produce
# a bundle with an empty version string.
VERSION_FILE="$(grep -rl 'enum SaplingVersion' Sources --include='*.swift' | head -1)"
VERSION="$(grep -o 'current = "[^"]*"' "$VERSION_FILE" | head -1 | cut -d'"' -f2)"
if [ -z "$VERSION" ]; then echo "error: could not determine version" >&2; exit 1; fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sapling"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Sapling</string>
    <key>CFBundleDisplayName</key>
    <string>Sapling</string>
    <key>CFBundleIdentifier</key>
    <string>dev.sapling.menubar</string>
    <key>CFBundleExecutable</key>
    <string>Sapling</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <!-- Menu bar only: no Dock icon, no main menu. -->
    <key>LSUIElement</key>
    <true/>
    <!--
      The control plane serves plain HTTP, bound to the Tailscale interface.
      Transport encryption is WireGuard's job, one layer down, and the API is
      unreachable off the tailnet — so TLS here would be a self-signed
      certificate protecting an already-encrypted tunnel.

      App Transport Security blocks cleartext for bundled apps regardless, and
      the daemon's address is configured by the user at runtime, so a domain
      exception cannot be declared ahead of time. Hence a blanket allowance.

      This is why `sapling status` worked while the app could not connect: a
      bare executable is not subject to ATS, an app bundle is.
    -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper lets it run locally. A real distribution
# build would use a Developer ID identity here.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "warning: ad-hoc codesign failed; the app may need to be opened via right-click > Open"

echo "Built $APP"
echo
echo "Install it:   cp -R \"$APP\" /Applications/"
echo "Run it now:   open \"$APP\""
