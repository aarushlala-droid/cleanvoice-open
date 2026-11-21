#!/bin/bash
# Builds CleanVoice.app from source and installs it to ~/Applications. No Xcode needed (Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")"

# The default 'swiftbuild' engine fails with the Command Line Tools on this Mac; the native one works.
if ! OUT=$(swift build -c release --build-system native 2>&1); then
    echo "$OUT" | grep -E "error" | sort -u
    echo "Build failed"
    exit 1
fi
BIN=".build/release/CleanVoice"

APP="build/CleanVoice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CleanVoice"

if [ ! -f build/AppIcon.icns ]; then
    swift make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
    rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CleanVoice</string>
    <key>CFBundleDisplayName</key><string>CleanVoice</string>
    <key>CFBundleIdentifier</key><string>local.cleanvoice.app</string>
    <key>CFBundleExecutable</key><string>CleanVoice</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/CleanVoice.app"
cp -R "$APP" "$HOME/Applications/CleanVoice.app"
echo "Installed: $HOME/Applications/CleanVoice.app"
