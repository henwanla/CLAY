#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")" && pwd)
flavor=preview
if [[ ${1:-} == --relay ]]; then flavor=relay; shift; fi
if [[ $# != 3 || "$1" != emulator-* ]]; then
  printf 'Usage: bash Platforms/Android/smoke-apk.sh [--relay] emulator-SERIAL APP.apk TEST.apk\n' >&2
  exit 64
fi
adb=("${ADB:-adb}" -P "${ANDROID_ADB_SERVER_PORT:-5037}" -s "$1")
[[ $("${adb[@]}" shell getprop ro.kernel.qemu | tr -d '\r') == 1 ]]
[[ $("${adb[@]}" shell getprop ro.product.cpu.abi | tr -d '\r') == arm64-v8a ]]
[[ $("${adb[@]}" shell getprop sys.boot_completed | tr -d '\r') == 1 ]]
app=org.clayrelay.$flavor
test_app=$app.tests
for package in "$app" "$test_app"; do
  if "${adb[@]}" shell pm path "$package" | grep -q '^package:'; then
    printf 'Use a disposable emulator without an existing %s installation.\n' "$package" >&2
    exit 1
  fi
done
umask 077
fixture_pid= work= installed_app=false installed_test=false
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [[ -n "$work" ]]; then rm -rf "$work"; fi
  if $installed_test; then "${adb[@]}" uninstall "$test_app" >/dev/null || true; fi
  if $installed_app; then "${adb[@]}" uninstall "$app" >/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$flavor" == relay ]]; then
  work=$(mktemp -d)
  (cd "$work" && exec python3 -B "$base/app/src/androidTest/relay-fixture.py") &
  fixture_pid=$!
  for _ in {1..100}; do
    if [[ -s "$work/fixture-ready" ]] || ! kill -0 "$fixture_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  [[ -s "$work/fixture-ready" ]] || { printf 'Relay loopback fixtures did not start.\n' >&2; exit 1; }
  IFS= read -r fixture < "$work/fixture-ready"
  [[ "$fixture" =~ ^([0-9]{1,5},){4}([a-f0-9]{24},){3}[a-f0-9]{64}$ ]]
fi
"${adb[@]}" install "$2"
installed_app=true
"${adb[@]}" install "$3"
installed_test=true
instrument() { "${adb[@]}" shell am instrument -w -r "$@" "$test_app/org.clayrelay.preview.PreviewInstrumentation" | tr -d '\r'; }
if [[ "$flavor" == relay ]]; then report=$(instrument -e relayFixture "$fixture"); else report=$(instrument); fi
printf '%s\n' "$report"
grep -qx 'CLAY_ANDROID_PREVIEW_PASS' <<< "$report"
grep -qx 'INSTRUMENTATION_CODE: -1' <<< "$report"
if [[ "$flavor" == relay ]]; then
  grep -qx 'CLAY_ANDROID_RELAY_PASS' <<< "$report"
  grep -qx 'CLAY_ANDROID_RELAY_FORWARDING_PASS' <<< "$report"
  grep -qx 'CLAY_ANDROID_SUBSCRIPTIONS_PASS' <<< "$report"
fi
