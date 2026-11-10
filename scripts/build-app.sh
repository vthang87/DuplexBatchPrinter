#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
app_name="PDF Duplex Batch Printer"
executable_name="PDFDuplexBatchPrinter"
app_bundle="$project_root/dist/$app_name.app"

cd "$project_root"
swift build -c "$configuration"

binary_path="$(swift build -c "$configuration" --show-bin-path)/$executable_name"
contents="$app_bundle/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"

cp "$binary_path" "$contents/MacOS/$executable_name"
cp "$project_root/Resources/Info.plist" "$contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"
chmod +x "$contents/MacOS/$executable_name"

# Ad-hoc signing lets Launch Services treat the local build as a normal app bundle.
codesign --force --deep --sign - "$app_bundle"

echo "$app_bundle"
