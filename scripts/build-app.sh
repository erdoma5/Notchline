#!/bin/bash
# Builds a zipped Notchline.app without leaving a second app in Launchpad.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARTIFACT="build/Notchline.app.zip"
VERSION="1.20.0"
SIGNING_IDENTITY="${NOTCHLINE_SIGNING_IDENTITY:-$(git config --local --get notchline.signingIdentity 2>/dev/null || true)}"
if [[ "$CONFIG" == "release" && ( -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ) ]]; then
  echo "Release builds require a stable signing identity; ad hoc signatures lose privacy grants." >&2
  exit 1
fi

# Builds one architecture and prints the binary's path.
# The Command Line Tools for macOS 27 ship an SDK whose SwiftUI needs a macro
# plugin they do not include. If the default SDK fails, fall back to the
# newest macOS 26 SDK installed alongside it.
build_arch() {
  local triple="$1-apple-macosx14.0"
  if [ -z "${SDKROOT:-}" ] && ! swift build --disable-sandbox -c "$CONFIG" --triple "$triple" >&2; then
    FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
    if [ -z "$FALLBACK" ]; then exit 1; fi
    echo "Retrying with $FALLBACK" >&2
    export SDKROOT="$FALLBACK"
  fi
  if [ -n "${SDKROOT:-}" ]; then swift build --disable-sandbox -c "$CONFIG" --triple "$triple" >&2; fi
  cp "$(swift build --disable-sandbox -c "$CONFIG" --triple "$triple" --show-bin-path)/Notchline" "$OUT/Notchline-$1"
}

# A universal binary, so it runs on Apple silicon and on Intel Macs, from
# macOS 14 Sonoma onwards.
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
build_arch arm64
build_arch x86_64
lipo -create "$OUT/Notchline-arm64" "$OUT/Notchline-x86_64" -output "$OUT/Notchline"
BIN="$OUT/Notchline"
APP="$OUT/Notchline.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchline"

# The icon is original artwork for Notchline, generated from vector paths.
WORK="$(mktemp -d)"
swift scripts/make-notched-icon.swift "$WORK/icon.png"
ICONSET="$WORK/Notchline.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Notchline.icns"
rm -rf "$WORK"

# Translations: one folder per language, listed in Info.plist so macOS knows
# which languages the app speaks.
LANGUAGES=""
for dir in Sources/Tendedero/Resources/*.lproj; do
  cp -R "$dir" "$APP/Contents/Resources/"
  LANGUAGES="$LANGUAGES<string>$(basename "$dir" .lproj)</string>"
done
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Upgrade identity: keep this name, executable and bundle ID stable. -->
  <key>CFBundleName</key><string>Notchline</string>
  <key>CFBundleDisplayName</key><string>Notchline</string>
  <key>CFBundleIdentifier</key><string>local.notchline.personal</string>
  <key>CFBundleExecutable</key><string>Notchline</string>
  <key>CFBundleIconFile</key><string>Notchline</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>48</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LANGUAGES}</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Notchline watches the folder where macOS saves your screenshots so it can hang them on the line.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Notchline watches the folder you chose so it can hang new images on the line.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Notchline watches the folder you chose so it can hang new images on the line.</string>
</dict>
</plist>
PLIST

# Reuse the configured signer on every release; a signing error must fail the build.
codesign --force --sign "${SIGNING_IDENTITY:--}" "$APP" >/dev/null
codesign --verify --strict --deep "$APP"
mkdir -p build
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARTIFACT"
echo "Built $ARTIFACT"
