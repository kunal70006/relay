#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
app_bundle="${1:-${task_root:h}/Relay.app}"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/relay-build.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
xcrun swift "$task_root/Tools/MakeIcon.swift" "$build_dir/Relay.iconset"
iconutil --convert icns "$build_dir/Relay.iconset" --output "$app_bundle/Contents/Resources/Relay.icns"
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -parse-as-library -target "${arch}-apple-macosx14.0" \
    "$task_root/Sources/TransferModel.swift" "$task_root/Sources/LocalTransfer.swift" "$task_root/Sources/RelayApp.swift" "$task_root/Sources/Verify.swift" \
    -o "$build_dir/Relay-$arch"
done
xcrun lipo -create "$build_dir/Relay-arm64" "$build_dir/Relay-x86_64" -output "$app_bundle/Contents/MacOS/Relay"
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
