#!/bin/zsh
# Builds PortWatch.app into ~/Applications
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/PortWatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/PortWatch" PortWatch.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>PortWatch</string>
<key>CFBundleIdentifier</key><string>local.portwatch</string>
<key>CFBundleExecutable</key><string>PortWatch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
