#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 && $1 =~ ^emulator-[0-9]+$ ]] || { printf 'Usage: %s emulator-SERIAL VPN.apk VPN-TEST.apk\n' "$0" >&2; exit 64; }
base=$(cd "$(dirname "$0")" && pwd)
adb=("${ADB:-adb}" -P "${ANDROID_ADB_SERVER_PORT:-5037}" -s "$1")
app=org.clayrelay.vpn
prop() { "${adb[@]}" shell getprop "$1" | tr -d '\r'; }
route() { "${adb[@]}" shell ip route show table all; }
has_tun() { grep -Eq ' dev tun[0-9]+([[:space:]]|$)' <<< "$1"; }
if [[ $(prop ro.kernel.qemu) != 1 || $(prop ro.product.cpu.abi) != arm64-v8a || $(prop ro.build.version.sdk) != 35 ||
    $(prop sys.boot_completed) != 1 ]] || has_tun "$(route)"; then
  printf 'Use a fully booted, disposable Android 15 ARM64 emulator without any active VPN.\n' >&2; exit 1
fi
for package in "$app" "$app.tests"; do
  if "${adb[@]}" shell pm path "$package" | grep -q '^package:'; then
    printf 'Remove existing test apps from this emulator first.\n' >&2; exit 1
  fi
done
work=$(mktemp -d "${TMPDIR:-/tmp}/clay-vpn-smoke.XXXXXX")
fixture= installed=false test_installed=false
cleanup() {
  if $test_installed; then "${adb[@]}" uninstall "$app.tests" >/dev/null || true; fi
  if $installed; then "${adb[@]}" uninstall "$app" >/dev/null || true; fi
  if [[ -n "$fixture" ]]; then kill "$fixture" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
(cd "$work" && exec python3 "$base/app/src/androidTest/vpn-fixture.py") &
fixture=$!
for _ in {1..30}; do [[ ! -s "$work/fixture-result" ]] || break; sleep 0.1; done
read -r first second direct proof < "$work/fixture-result"
"${adb[@]}" install -g "$2"
installed=true
"${adb[@]}" install -t "$3"
test_installed=true
# Only the disposable emulator is pre-authorized. End users still use VpnService.prepare().
"${adb[@]}" shell appops set "$app" ACTIVATE_VPN allow
for cycle in 1 2; do
  report=$("${adb[@]}" shell am instrument -w -r -e firstPort "$first" -e secondPort "$second" \
    -e directPort "$direct" -e proof "$proof" "$app.tests/org.clayrelay.preview.PreviewInstrumentation" | tr -d '\r')
  printf '%s\n' "$report"
  grep -qx 'CLAY_ANDROID_VPN_PASS' <<< "$report"
  grep -qx 'INSTRUMENTATION_CODE: -1' <<< "$report"
  current=$(route)
  if has_tun "$current"; then printf 'VPN route remains after stop (cycle %s).\n' "$cycle" >&2; exit 1; fi
done
