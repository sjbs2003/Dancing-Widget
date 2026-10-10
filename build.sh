#!/bin/zsh
# Builds MastiKhor.app (no Xcode needed — Command Line Tools are enough).
set -e
cd "$(dirname "$0")"
APP=build/MastiKhor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/MastiKhor" Sources/main.swift
cp Resources/* "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.surajbarik.mastikhor</string>
  <key>CFBundleName</key><string>MastiKhor</string>
  <key>CFBundleExecutable</key><string>MastiKhor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Checks whether Apple Music is already playing when you switch the dancer on.</string>
</dict></plist>
EOF
codesign --force -s - "$APP"
echo "Built $APP"
