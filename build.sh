#!/bin/bash
set -eu
cd "$(dirname "$0")"
APP=build/YogaControl.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -parse-as-library -framework IOKit -o "$APP/Contents/MacOS/YogaControl" YogaControl.swift
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>YogaControl</string>
    <key>CFBundleIdentifier</key><string>local.yoga14s.YogaControl</string>
    <key>CFBundleName</key><string>Yoga 14s 控制</string>
    <key>CFBundleDisplayName</key><string>Yoga 14s 控制</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "built $APP"
