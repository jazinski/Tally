#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
APP="Tally"
VERSION="0.0.1"
DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"')
echo "▸ $APP — building..."
pkill -x "$APP" 2>/dev/null && sleep 1 || true
mkdir -p build
FW_PATH="$(pwd)/../Sashay/Frameworks"
swiftc -parse-as-library -O -F "$FW_PATH" \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -framework AppKit -framework CoreGraphics -framework ApplicationServices -framework Sparkle \
  -o "build/$APP" "$APP.swift" ActivityEngine.swift FocusEngine.swift License.swift
rm -rf "$APP.app"
mkdir -p "$APP.app/Contents/MacOS" "$APP.app/Contents/Frameworks" "$APP.app/Contents/Resources"
cp "build/$APP" "$APP.app/Contents/MacOS/$APP"
cp -R "$FW_PATH/Sparkle.framework" "$APP.app/Contents/Frameworks/"
cat > "$APP.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tally</string>
    <key>CFBundleDisplayName</key><string>Tally</string>
    <key>CFBundleExecutable</key><string>Tally</string>
    <key>CFBundleIdentifier</key><string>com.jazinski.tally</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>SUFeedURL</key><string>https://sashay.dev/tally-appcast.xml</string>
    <key>SUPublicEDKey</key><string>04uW74rV4uq9oLDVi3RuyL8kbBRcvWi8MejOsPBUZkE=</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>Tally.icns</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSAccessibilityUsageDescription</key><string>Tally Ho uses accessibility to see which app is frontmost so it can track your day locally. Nothing ever leaves your Mac.</string>
</dict>
</plist>
PLIST
if [[ -f assets/icon_1024.png ]]; then
    ICONSET="build/icon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP.app/Contents/Resources/$APP.icns"
fi
if [[ -n "$DEVID" ]]; then
    SPK="$APP.app/Contents/Frameworks/Sparkle.framework/Versions/B"
    codesign --force --options runtime --timestamp --sign "$DEVID" "$SPK/Updater.app" 2>/dev/null || true
    codesign --force --options runtime --timestamp --sign "$DEVID" "$SPK/Autoupdate" 2>/dev/null || true
    for xpc in "$SPK/XPCServices"/*/; do codesign --force --options runtime --timestamp --sign "$DEVID" "$xpc"; done
    codesign --force --options runtime --timestamp --sign "$DEVID" "$APP.app/Contents/Frameworks/Sparkle.framework"
    codesign --force --options runtime --timestamp --sign "$DEVID" "$APP.app"
    codesign --verify --strict "$APP.app" && echo "  signed ✓"
fi
echo "✓ Built: $(pwd)/$APP.app"
