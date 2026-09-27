#!/bin/zsh
# Builds "Pomo Lite.app" from ../index.html
#   ./build.sh             -> /Applications/Pomo Lite.app
#   ./build.sh --snapshot  -> build/Pomo Lite.app (debug build for testing, separate app data)
set -euo pipefail
cd "${0:A:h}"
app="/Applications/Pomo Lite.app"
flags=()
if [[ "${1:-}" == "--snapshot" ]]; then app="$PWD/build/Pomo Lite.app"; flags=(-D SNAPSHOT); fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O $flags main.swift -o "$app/Contents/MacOS/PomoLite"
cp Info.plist "$app/Contents/"
[[ -n "$flags" ]] && plutil -replace CFBundleIdentifier -string local.pomolite.debug "$app/Contents/Info.plist"
cp ../index.html break.wav focus.wav count.wav AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "built: $app"
