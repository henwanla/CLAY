#!/usr/bin/env bash
set -euo pipefail
[[ $# == 4 && $1 =~ ^emulator-[0-9]+$ ]] || { printf 'Usage: %s emulator-SERIAL VPN.apk VPN-TEST.apk REVOKER.apk\n' "$0" >&2; exit 64; }
base=$(cd "$(dirname "$0")" && pwd)
adb=("${ADB:-adb}" -P "${ANDROID_ADB_SERVER_PORT:-5037}" -s "$1")
app=org.clayrelay.vpn
revoker=org.clayrelay.vpnrevoker
prop() { "${adb[@]}" shell getprop "$1" | tr -d '\r'; }
route() { "${adb[@]}" shell 'ip route show table all; ip -6 route show table all'; }
has_tun() { grep -Eq ' dev tun[0-9]+([[:space:]]|$)' <<< "$1"; }
if [[ $(prop ro.kernel.qemu) != 1 || $(prop ro.product.cpu.abi) != arm64-v8a || $(prop ro.build.version.sdk) != 35 ||
    $(prop sys.boot_completed) != 1 ]] || has_tun "$(route)"; then
  printf 'Use a fully booted, disposable Android 15 ARM64 emulator without any active VPN.\n' >&2; exit 1
fi
for package in "$app" "$app.tests" "$revoker"; do
  if "${adb[@]}" shell pm path "$package" | grep -q '^package:'; then
    printf 'Remove existing test apps from this emulator first.\n' >&2; exit 1
  fi
done
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/clay-vpn-smoke.XXXXXX")
fixture= upstream_pid= watch_pid= installed=false test_installed=false revoker_installed=false
cleanup() {
  if [[ -n "$watch_pid" ]]; then kill "$watch_pid" 2>/dev/null || true; fi
  if $revoker_installed; then "${adb[@]}" uninstall "$revoker" >/dev/null || true; fi
  if $test_installed; then "${adb[@]}" uninstall "$app.tests" >/dev/null || true; fi
  if $installed; then "${adb[@]}" uninstall "$app" >/dev/null || true; fi
  if [[ -n "$upstream_pid" ]]; then kill "$upstream_pid" 2>/dev/null || true; fi
  if [[ -n "$fixture" ]]; then kill "$fixture" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
(cd "$work" && exec python3 -B "$base/app/src/androidTest/vpn-fixture.py") &
fixture=$!
for _ in {1..100}; do
  if [[ -s "$work/fixture-result" ]] || ! kill -0 "$fixture" 2>/dev/null; then break; fi
  sleep 0.1
done
[[ -s "$work/fixture-result" ]] || { printf 'The loopback test fixtures did not start.\n' >&2; exit 1; }
read -r first second direct ipv6 tls ipv6_origin udp4 udp6 proof cert < "$work/fixture-result"
"${adb[@]}" install -g "$2"
installed=true
"${adb[@]}" install -t "$3"
test_installed=true
"${adb[@]}" install -t "$4"
revoker_installed=true

instrument() {
  # Every payload is synthetic; the tool never accepts arbitrary profiles or destinations.
  "${adb[@]}" shell am instrument -w -r -e firstPort "$first" -e secondPort "$second" \
    -e directPort "$direct" -e ipv6Port "$ipv6" -e ipv6OriginPort "$ipv6_origin" -e tlsPort "$tls" -e proof "$proof" -e tlsCert "$cert" \
    -e udp4Port "$udp4" -e udp6Port "$udp6" \
    "$@" "$app.tests/org.clayrelay.preview.PreviewInstrumentation"
}
check_result() {
  local report current
  report=$(tr -d '\r' < "$1")
  printf '%s\n' "$report"
  if [[ -e "$work/unexpected-direct-udp" ]]; then printf 'A UDP packet marked PROXY reached the local origin.\n' >&2; exit 1; fi
  if [[ -e "$work/unexpected-direct-http" ]]; then printf 'A TCP request in Global mode reached the direct origin.\n' >&2; exit 1; fi
  grep -qx "$2" <<< "$report"
  grep -qx 'CLAY_ANDROID_SUBSCRIPTIONS_PASS' <<< "$report"
  grep -qx 'INSTRUMENTATION_CODE: -1' <<< "$report"
  current=$(route)
  if has_tun "$current"; then printf 'VPN route remains after %s.\n' "$2" >&2; exit 1; fi
}

# First exercise a real cancellation without preauthorizing CLAY.
instrument -e vpnFault cancel > "$work/report"
check_result "$work/report" CLAY_ANDROID_VPN_CONSENT_CANCEL_PASS
# Only the fixtures on this disposable emulator are preauthorized.
"${adb[@]}" shell appops set "$app" ACTIVATE_VPN allow
"${adb[@]}" shell appops set "$revoker" ACTIVATE_VPN allow
for resolver in v4 v6; do
  printf 'Checking Android system DNS over %s\n' "$resolver"
  instrument -e resolver "$resolver" > "$work/report"
  check_result "$work/report" CLAY_ANDROID_VPN_PASS
done
instrument -e vpnFault engine > "$work/report"
check_result "$work/report" CLAY_ANDROID_VPN_ENGINE_EXIT_PASS

# Wait for the working tunnel before transferring authorization to the second package.
instrument -e vpnFault revoke > "$work/revoke" &
watch_pid=$!
for _ in {1..100}; do
  if grep -q CLAY_ANDROID_AWAIT_REVOKE "$work/revoke"; then break; fi
  if ! kill -0 "$watch_pid" 2>/dev/null; then break; fi
  sleep 0.15
done
if ! grep -q CLAY_ANDROID_AWAIT_REVOKE "$work/revoke" ||
    ! "${adb[@]}" shell 'ip -6 route show table all' | grep -Eq '^default dev tun[0-9]+([[:space:]]|$)'; then
  cat "$work/revoke" >&2
  printf 'CLAY tunnel never reached the revocation checkpoint.\n' >&2
  exit 1
fi
replacement=$("${adb[@]}" shell am instrument -w -r "$revoker/.Revoker" | tr -d '\r')
grep -qx 'CLAY_ANDROID_REPLACEMENT_PREPARED' <<< "$replacement"
grep -qx 'INSTRUMENTATION_CODE: -1' <<< "$replacement"
wait "$watch_pid"
watch_pid=
check_result "$work/revoke" CLAY_ANDROID_VPN_REVOKE_PASS

# The upstreams accept only the exact QEMU alias and synthetic origin port, and never dial out.
(cd "$work" && exec python3 -B "$base/app/src/androidTest/relay-fixture.py" --vpn "$direct") &
upstream_pid=$!
for _ in {1..100}; do
  if [[ -s "$work/fixture-ready" ]] || ! kill -0 "$upstream_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
[[ -s "$work/fixture-ready" ]] || { printf 'The loopback upstream fixtures did not start.\n' >&2; exit 1; }
# The earlier revocation test transferred permission to the synthetic revoker.
"${adb[@]}" shell appops set "$app" ACTIVATE_VPN allow
instrument -e vpnFault forwarding -e forwardingFixture "$(cat "$work/fixture-ready")" > "$work/report"
check_result "$work/report" CLAY_ANDROID_VPN_FORWARDING_PASS
