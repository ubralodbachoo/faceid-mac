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
mkdir -p "$app/Contents/Resources"
if [[ -d Models/ArcFace.mlpackage ]]; then
    python3 tools/check_model_assets.py
    compiled="$PWD/build/compiled-models"
    mkdir -p "$compiled"
    # Only remove reproducible derived assets, never user data or model source weights.
    rm -rf "$compiled/ArcFace.mlmodelc" "$app/Contents/Resources/ArcFace.mlmodelc"
    xcrun coremlcompiler compile Models/ArcFace.mlpackage "$compiled"
    cp -R "$compiled/ArcFace.mlmodelc" "$app/Contents/Resources/ArcFace.mlmodelc"
    cp Models/ArcFaceReference.json "$app/Contents/Resources/ArcFaceReference.json"
    cp Models/model-provenance.lock.json "$app/Contents/Resources/ArcFaceProvenance.json"
    cp Models/NOTICE.md "$app/Contents/Resources/ArcFace-NOTICE.md"
    cp Models/Glance-MIT-LICENSE.txt "$app/Contents/Resources/Glance-MIT-LICENSE.txt"
else
    # A source-only checkout still builds, but never retains a stale compiled model.
    rm -rf "$app/Contents/Resources/ArcFace.mlmodelc"
fi
codesign --force --sign - "$app"
printf 'Built development app: %s\n' "$app"
