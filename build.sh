#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
app_bundle="${1:-${task_root:h}/Relay.app}"
icon_dir=$(mktemp -d "${TMPDIR:-/tmp}/relay-icon.XXXXXX")
trap 'rm -rf -- "$icon_dir"' EXIT
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
xcrun swift "$task_root/Tools/MakeIcon.swift" "$icon_dir/Relay.iconset"
iconutil --convert icns "$icon_dir/Relay.iconset" --output "$app_bundle/Contents/Resources/Relay.icns"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
  "$task_root/Sources/TransferModel.swift" "$task_root/Sources/LocalTransfer.swift" "$task_root/Sources/RelayApp.swift" "$task_root/Sources/Verify.swift" \
  -o "$app_bundle/Contents/MacOS/Relay"
cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Relay</string>
<key>CFBundleIdentifier</key><string>local.relay.filetransfer</string>
<key>CFBundleName</key><string>Relay</string>
<key>CFBundleDisplayName</key><string>Relay</string>
<key>CFBundleIconFile</key><string>Relay.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.1</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>Relay sends and receives files with devices on your Wi-Fi during a session you start.</string>
</dict></plist>
PLIST
cp "$task_root/Resources/local.html" "$app_bundle/Contents/Resources/local.html"
codesign --force --sign - "$app_bundle"
echo "Built: $app_bundle"
