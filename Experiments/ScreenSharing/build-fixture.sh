#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
app="$root/.build/screen-sharing-lifecycle/ResizeWindow.app"
mkdir -p "$app/Contents/MacOS"
xcrun --sdk macosx clang -fobjc-arc -framework AppKit "$root/Experiments/ScreenSharing/ResizeWindow.m" -o "$app/Contents/MacOS/ResizeWindow"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.vsmirn0v.screenresizefixture</string>
<key>CFBundleName</key><string>Presenter Resize Test</string>
<key>CFBundleExecutable</key><string>ResizeWindow</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
