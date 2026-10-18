#!/bin/sh
# Build Tiro and install it on a connected iPhone.
#
#   ./scripts/install-on-iphone.sh [bundle-id]
#
# Before the first run: Xcode → Settings → Accounts → add your Apple ID, plug
# the phone in, unlock it, tap Trust, and turn on Developer Mode
# (Settings → Privacy & Security). The team id is read from your Xcode
# account; pass a bundle id only you use on the first run (com.yourname.tiro).
set -eu
cd "$(dirname "$0")/.."

[ -d Vendor/whisper.xcframework ] && [ -d Tiro.xcodeproj ] || ./scripts/bootstrap.sh

# The first connected, paired iPhone.
UDID="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /connected|available \(paired\)/ && !/simulated/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)"
if [ -z "$UDID" ]; then
  echo "No connected iPhone. Plug it in, unlock it, and tap Trust." >&2
  xcrun devicectl list devices >&2 || true
  exit 1
fi

. scripts/signing.sh
ensure_signing "${1:-}"

echo "Building for $UDID…"
xcodebuild -project Tiro.xcodeproj -scheme Tiro -configuration Release \
  -destination "id=$UDID" -derivedDataPath build/device \
  -allowProvisioningUpdates build | grep -E "error:|warning: .*provision|BUILD (SUCCEEDED|FAILED)" || true

APP="build/device/Build/Products/Release-iphoneos/Tiro.app"
[ -d "$APP" ] || { echo "Build failed; run without the grep filter to see why." >&2; exit 1; }

echo "Installing…"
xcrun devicectl device install app --device "$UDID" "$APP"
echo "Installed. If the phone says 'Untrusted Developer': Settings → General → VPN & Device Management → trust your Apple ID."
