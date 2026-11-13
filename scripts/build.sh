#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Build/MiScrcpy Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.samni.miscrcpymac</string>
<key>CFBundleName</key><string>MiScrcpy Mac</string>
<key>CFBundleDisplayName</key><string>MiScrcpy Mac</string>
<key>CFBundleExecutable</key><string>MiScrcpyMac</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/clang -fobjc-arc -fmodules -O2 -mmacosx-version-min=12.0 \
  -framework Cocoa -framework QuartzCore -framework CoreGraphics \
  "$ROOT/Sources/main.m" -o "$APP/Contents/MacOS/MiScrcpyMac"
chmod +x "$APP/Contents/MacOS/MiScrcpyMac"
/usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1
echo "APP_BUILT=$APP"
"$APP/Contents/MacOS/MiScrcpyMac" --self-test
mkdir -p "$ROOT/Build/dmg"
rm -rf "$ROOT/Build/dmg/MiScrcpy Mac.app"
cp -R "$APP" "$ROOT/Build/dmg/MiScrcpy Mac.app"
ln -sfn /Applications "$ROOT/Build/dmg/Applications"
cp "$ROOT/README.md" "$ROOT/Build/dmg/使用说明.txt"
/usr/bin/hdiutil create -ov -volname "MiScrcpy Mac" -srcfolder "$ROOT/Build/dmg" \
 -format UDZO "$ROOT/dist/MiScrcpy-Mac-0.1.0.dmg" >/dev/null
echo "DMG_BUILT=$ROOT/dist/MiScrcpy-Mac-0.1.0.dmg"
