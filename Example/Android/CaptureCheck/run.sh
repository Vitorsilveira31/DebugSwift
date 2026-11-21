#!/bin/sh
# Builds CaptureCheck for Android and runs it on the connected device or emulator (ANDROID_SERIAL
# picks one). It checks DebugSwift's URLSession capture against swift-corelibs-foundation: host
# protocols, downloads, timeouts, body masking, rewrites and stops. Exits non-zero on a failure.
#
# Needs the Swift Android SDK matching the host toolchain (`skip android sdk install`) and adb.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
cd "$here"

# Always the code in this checkout: DebugSwiftCore, and the DebugSwiftUI files under test with
# their Android guards lifted.
ui="$repo/DebugSwiftUI/Sources/DebugSwiftUI"
rm -rf Sources/DebugSwiftCore Sources/CaptureCheck/Copied
mkdir -p Sources/CaptureCheck/Copied
cp -R "$repo/DebugSwiftCore/Sources/DebugSwiftCore" Sources/DebugSwiftCore
for file in Network/DebugSwiftURLSessionCapture.swift Network/DebugSwiftNetworkInjection.swift \
    Network/DebugSwiftNetworkInjectionPatch.swift AndroidAPI/DebugSwiftPresentation.swift; do
    sed 's/^#if os(Android)$/#if true/' "$ui/$file" > "Sources/CaptureCheck/Copied/$(basename "$file")"
done

swift build --swift-sdk aarch64-unknown-linux-android28 -c debug
binary=$(find .build -type f -name CaptureCheck -perm -u+x -path '*android*' | head -1)
sdk=$(find "$HOME/Library/org.swift.swiftpm/swift-sdks" "$HOME/.swiftpm/swift-sdks" -maxdepth 1 -name '*android*' 2>/dev/null | sort | tail -1)/swift-android
libs="$sdk/swift-resources/usr/lib/swift-aarch64/android"
cxx=$(find "$sdk" -name libc++_shared.so -path '*aarch64*' | head -1)

remote=/data/local/tmp/debugswift-capture-check
adb shell rm -rf "$remote"
adb shell mkdir -p "$remote"
for file in "$libs"/*.so "$cxx" "$binary"; do adb push "$file" "$remote/" >/dev/null 2>&1; done
status=0
adb shell "cd $remote && chmod +x CaptureCheck && TMPDIR=$remote LD_LIBRARY_PATH=. ./CaptureCheck; echo exit=\$?" | tee "$here/.last-run.txt"
grep -q '^exit=0' "$here/.last-run.txt" || status=1
adb shell rm -rf "$remote"
exit $status
