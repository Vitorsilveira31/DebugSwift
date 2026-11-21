#!/bin/sh
# Installs the Example app and its instrumented tests on the connected device or emulator, runs the
# tests, and exits non-zero when any fails. `am instrument` itself exits 0 on test failures, so
# the result is read from its output. PushRestartTest runs last, in two stages across a restart.
#
# Usage: run-instrumented-tests.sh <directory holding app-debug.apk and app-debug-androidTest.apk>
set -eu

apk_dir=${1:?pass the directory holding the APKs}
runner=com.debugswift.example.test/debug.swift.example.DebugSwiftTestRunner

# -g grants the runtime permissions, such as notifications, that the app asks for at launch.
adb install -r -g "$apk_dir/app-debug.apk"
adb install -r "$apk_dir/app-debug-androidTest.apk"

restart_test=debug.swift.example.PushRestartTest

passed() { echo "$1" | grep -q '^OK ('; }

output=$(adb shell am instrument -w -r -e notClass "$restart_test" "$runner")
echo "$output"
passed "$output" || { echo "Instrumented tests failed." >&2; exit 1; }

# Push state across a real restart: each `am instrument` starts a fresh app process, and
# force-stop ends the one that saved the state before the next reads it back.
save=$(adb shell am instrument -w -r -e class "$restart_test#savesPushState" -e pushRestartStage save "$runner")
echo "$save"
passed "$save" || { echo "Saving push state for the restart test failed." >&2; exit 1; }
adb shell am force-stop com.debugswift.example
check=$(adb shell am instrument -w -r -e class "$restart_test#readsPushStateAfterARestart" -e pushRestartStage check "$runner")
echo "$check"
passed "$check" || { echo "Push state did not survive a restart." >&2; exit 1; }
