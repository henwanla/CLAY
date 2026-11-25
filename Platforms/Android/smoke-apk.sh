#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 || "$1" != emulator-* ]]; then
  printf 'Usage: bash Platforms/Android/smoke-apk.sh emulator-SERIAL PREVIEW.apk TEST.apk\n' >&2
  exit 64
fi
adb=("${ADB:-adb}" -P "${ANDROID_ADB_SERVER_PORT:-5037}" -s "$1")
[[ $("${adb[@]}" shell getprop ro.kernel.qemu | tr -d '\r') == 1 ]]
[[ $("${adb[@]}" shell getprop ro.product.cpu.abi | tr -d '\r') == arm64-v8a ]]
[[ $("${adb[@]}" shell getprop sys.boot_completed | tr -d '\r') == 1 ]]
app=org.clayrelay.preview
test_app=org.clayrelay.preview.tests
for package in "$app" "$test_app"; do
  if "${adb[@]}" shell pm path "$package" | grep -q '^package:'; then
    printf 'Use a disposable emulator without an existing %s installation.\n' "$package" >&2
    exit 1
  fi
done
installed_app=false; installed_test=false
cleanup() {
  if $installed_test; then "${adb[@]}" uninstall "$test_app" >/dev/null || true; fi
  if $installed_app; then "${adb[@]}" uninstall "$app" >/dev/null || true; fi
}
trap cleanup EXIT
"${adb[@]}" install "$2"
installed_app=true
"${adb[@]}" install "$3"
installed_test=true
report=$("${adb[@]}" shell am instrument -w -r "$test_app/$app.PreviewInstrumentation" | tr -d '\r')
printf '%s\n' "$report"
grep -qx 'CLAY_ANDROID_PREVIEW_PASS' <<< "$report"
grep -qx 'INSTRUMENTATION_CODE: -1' <<< "$report"
