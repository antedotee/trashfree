#!/bin/zsh
# Builds the SwiftPM executable and wraps it in a .app bundle so macOS treats it
# as a regular GUI app (Dock icon, key window, NSOpenPanel, accessibility tree).
set -euo pipefail

root="${0:A:h:h}"
config="${1:-debug}"
cd "$root"

if [[ "$config" == release ]]; then
  # One build per architecture, joined with lipo, so the app runs on Apple silicon and
  # Intel Macs. `--arch a --arch b` would need Xcode's xcbuild; this needs only the
  # Command Line Tools.
  slices=()
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx13.0"
    swift build -c release --triple "$triple" --product TrashFreeApp
    slices+=("$(swift build -c release --triple "$triple" --show-bin-path)/TrashFreeApp")
  done
  bin="$root/.build/TrashFree-universal"
  lipo -create "${slices[@]}" -output "$bin"
else
  swift build -c "$config"
  bin="$(swift build -c "$config" --show-bin-path)/TrashFreeApp"
fi

app="$root/build/TrashFree.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/TrashFree"
[[ -f "$root/Resources/AppIcon.icns" ]] && cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TrashFree</string>
    <key>CFBundleIdentifier</key><string>dev.kartikyadav.trashfree</string>
    <key>CFBundleName</key><string>TrashFree</string>
    <key>CFBundleDisplayName</key><string>TrashFree</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# A stable signature keeps macOS privacy grants across rebuilds.
"$root/scripts/signing-identity.sh" "$app"

echo "$app"
