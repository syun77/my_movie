#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/my_movie-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/my_movie-swift-cache"
swift build -c release --disable-sandbox --cache-path "${TMPDIR:-/tmp}/my_movie-spm-cache"
app="$(pwd)/dist/MV Studio.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/MVStudio "$app/Contents/MacOS/MVStudio"
ditto .build/release/MVStudio_MVStudio.bundle "$app/Contents/Resources/MVStudio_MVStudio.bundle"
mkdir -p "$app/Contents/Resources/Licenses"
cp ThirdParty/spine-cpp/LICENSE "$app/Contents/Resources/Licenses/Spine-Runtimes.txt"
cp ThirdParty/spine-cpp/README.md "$app/Contents/Resources/Licenses/Spine-Source.md"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MVStudio</string>
<key>CFBundleIdentifier</key><string>local.mymovie.MVStudio</string>
<key>CFBundleName</key><string>MV Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf 'Built: %s\n' "$app"
