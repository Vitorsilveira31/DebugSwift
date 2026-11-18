#!/bin/sh
# Installs the sample and its instrumented tests on the connected device or emulator, runs the
# tests, and exits non-zero when any fails. `am instrument` itself exits 0 on test failures, so
# the result is read from its output.
#
# Usage: run-instrumented-tests.sh <directory holding app-debug.apk and app-debug-androidTest.apk>
set -eu

apk_dir=${1:?pass the directory holding the APKs}
runner=com.debugswift.example.android.test/debug.swift.android.sample.DebugSwiftTestRunner

adb install -r "$apk_dir/app-debug.apk"
adb install -r "$apk_dir/app-debug-androidTest.apk"

output=$(adb shell am instrument -w -r "$runner")
echo "$output"

if echo "$output" | grep -q '^OK ('; then
    exit 0
fi
echo "Instrumented tests failed." >&2
exit 1
