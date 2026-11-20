#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

edition="${1:-admin}"
case "$edition" in
    admin)
        configuration=debug
        swift_flags=(-Xswiftc -DFACEUNLOCK_ADMIN)
        app_name="Face Unlock"
        bundle_id="org.faceunlock.development"
        ;;
    customer)
        configuration=release
        swift_flags=(-Xswiftc -DFACEUNLOCK_CUSTOMER)
        app_name="Face Unlock Customer"
        bundle_id="org.faceunlock.customer"
        ;;
    *) printf 'Usage: %s [admin|customer]\n' "$0" >&2; exit 2 ;;
esac

# Keep toolchain caches inside the project for reproducible local development.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --disable-sandbox -c "$configuration" --product FaceUnlock "${swift_flags[@]}"
bin_dir="$(swift build --disable-sandbox -c "$configuration" "${swift_flags[@]}" --show-bin-path)"
app="$PWD/build/$app_name.app"
mkdir -p "$app/Contents/MacOS"
# Replace the executable inode instead of modifying pages of a running build.
cp "$bin_dir/FaceUnlock" "$app/Contents/MacOS/.FaceUnlock.new"
mv -f "$app/Contents/MacOS/.FaceUnlock.new" "$app/Contents/MacOS/FaceUnlock"
cp scripts/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FaceUnlockEdition string $edition" "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp Models/Glance-MIT-LICENSE.txt "$app/Contents/Resources/Glance-MIT-LICENSE.txt"
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
else
    # A source-only checkout still builds, but never retains a stale compiled model.
    rm -rf "$app/Contents/Resources/ArcFace.mlmodelc"
fi
if [[ -d Models/PassivePAD.mlpackage ]]; then
    python3 tools/check_passive_pad_assets.py
    mkdir -p build/compiled-models
    rm -rf build/compiled-models/PassivePAD.mlmodelc "$app/Contents/Resources/PassivePAD.mlmodelc"
    xcrun coremlcompiler compile Models/PassivePAD.mlpackage build/compiled-models
    cp -R build/compiled-models/PassivePAD.mlmodelc "$app/Contents/Resources/PassivePAD.mlmodelc"
    cp Models/PassivePADReference.json Models/Minivision-Apache-LICENSE.txt "$app/Contents/Resources/"
else
    rm -rf "$app/Contents/Resources/PassivePAD.mlmodelc"
fi
codesign --force --sign - "$app"
printf 'Built %s app (ad-hoc signed): %s\n' "$edition" "$app"
