#!/bin/sh
# Archive Tiro and upload it to App Store Connect for TestFlight.
#
#   ./scripts/testflight.sh [bundle-id]
#
# Before the first run:
#   - Xcode → Settings → Accounts: your Apple ID (paid developer program),
#     with an Apple Development certificate (Manage Certificates → +).
#   - App Store Connect → Apps → + New App, with the same bundle id, so the
#     upload has a place to land. Xcode registers the bundle id, the
#     keyboard's id and the App Group for you on the first archive, so run
#     this once before creating the app if the id isn't in the list yet.
# Every run gets a fresh build number (timestamp), as App Store Connect requires.
set -eu
cd "$(dirname "$0")/.."

[ -d Vendor/whisper.xcframework ] && [ -d Tiro.xcodeproj ] || ./scripts/bootstrap.sh
. scripts/signing.sh
ensure_signing "${1:-}"

TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Signing.local.xcconfig)"
BUILD="$(date +%Y%m%d%H%M)"
ARCHIVE="build/Tiro-$BUILD.xcarchive"
mkdir -p build

echo "Archiving build $BUILD…"
xcodebuild -project Tiro.xcodeproj -scheme Tiro -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive \
  | grep -E "error:|BUILD|ARCHIVE (SUCCEEDED|FAILED)" || true
[ -d "$ARCHIVE" ] || { echo "Archive failed; rerun the xcodebuild line without the grep to see why." >&2; exit 1; }

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
PLIST

echo "Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates
echo "Uploaded build $BUILD. It shows up in App Store Connect → TestFlight after processing (usually 5–20 min)."
