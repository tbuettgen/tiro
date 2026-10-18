#!/bin/sh
# Fetch whisper.cpp's prebuilt Apple framework and generate Tiro.xcodeproj.
# Needs: Xcode, xcodegen (brew install xcodegen), curl, unzip.
set -eu
cd "$(dirname "$0")/.."

WHISPER_TAG="${WHISPER_TAG:-b5454}"
if [ ! -d Vendor/whisper.xcframework ]; then
  echo "Fetching whisper.cpp $WHISPER_TAG xcframework…"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/whisper.zip" \
    "https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_TAG/whisper-$WHISPER_TAG-xcframework.zip"
  unzip -q "$tmp/whisper.zip" -d "$tmp/x"
  mkdir -p Vendor
  mv "$tmp/x/build-apple/whisper.xcframework" Vendor/
  # Tiro only ships on iOS; drop the other platforms' slices.
  for slice in Vendor/whisper.xcframework/*/; do
    case "$(basename "$slice")" in ios-*) ;; *) rm -rf "$slice" ;; esac
  done
  rm -rf "$tmp"
fi

xcodegen generate --quiet
echo "Done. Open Tiro.xcodeproj, or see README.md for command-line builds."
