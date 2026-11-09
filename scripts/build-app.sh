#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep toolchain caches inside the project for reproducible local development.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --disable-sandbox -c debug
bin_dir="$(swift build --disable-sandbox -c debug --show-bin-path)"
app="$PWD/build/Face Unlock.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/FaceUnlock" "$app/Contents/MacOS/FaceUnlock"
cp scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf 'Built development app: %s\n' "$app"
