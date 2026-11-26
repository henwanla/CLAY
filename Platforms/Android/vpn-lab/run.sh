#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 || ! "$1" =~ ^emulator-[0-9]+$ ]]; then
  printf 'Usage: bash %s emulator-SERIAL MIHOMO_V1.19.34_SOURCE_TGZ\n' "$0" >&2
  exit 64
fi
lab=$(cd "$(dirname "$0")" && pwd)
archive=$2
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK with Platform 35 and Build Tools 36.0.0}"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to NDK r30}"
: "${JAVA_HOME:?Set JAVA_HOME to JDK 17}"
export PATH="$JAVA_HOME/bin:$PATH"
bt="$ANDROID_HOME/build-tools/36.0.0"
platform="$ANDROID_HOME/platforms/android-35/android.jar"
case $(uname -s) in
  Darwin) host=darwin-x86_64 ;;
  Linux) host=linux-x86_64 ;;
  *) exit 64 ;;
esac
ndk="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host"
expected=e3284a44f1052f1c454c90d418faa244516c2470bf232b455ea18fc4f5fa6028
[[ $(shasum -a 256 < "$archive" | cut -d ' ' -f 1) == "$expected" ]]

adb=("${ADB:-$ANDROID_HOME/platform-tools/adb}" -P "${ANDROID_ADB_SERVER_PORT:-5037}" -s "$1")
prop() { "${adb[@]}" shell getprop "$1" | tr -d '\r'; }
routes() { "${adb[@]}" shell ip route show table all; }
vpn_routes() { grep -E ' dev tun[0-9]+([[:space:]]|$)' <<< "$1" >/dev/null; }
package=org.clayrelay.vpnprobe
if [[ $(prop ro.kernel.qemu) != 1 || $(prop ro.product.cpu.abi) != arm64-v8a ||
      $(prop sys.boot_completed) != 1 || $(prop ro.build.version.sdk) != 24 ]]; then
  printf 'Use a fully booted, disposable Android API 24 ARM64 emulator.\n' >&2
  exit 1
fi
existing_routes=$(routes)
if vpn_routes "$existing_routes" || "${adb[@]}" shell pm path "$package" | grep -q '^package:'; then
  printf 'The emulator already has a TUN route or a copy of this test APK.\n' >&2
  exit 1
fi

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/clay-vpn-lab.XXXXXX")
fixture_pid= test_pid= installed=false guest_client=
cleanup() {
  if [[ -n "$test_pid" ]]; then kill "$test_pid" 2>/dev/null || true; fi
  if $installed; then "${adb[@]}" uninstall "$package" >/dev/null || true; fi
  if [[ -n "$guest_client" ]]; then "${adb[@]}" shell rm -f "$guest_client" >/dev/null || true; fi
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/src" "$work/lib/arm64-v8a" "$work/classes"
tar -xzf "$archive" --strip-components=1 -C "$work/src"
(cd "$work/src" && git apply --unidiff-zero "$lab/external-tun.patch")
cp "$lab/protect_android.go" "$work/src/clay_protect_android.go"
(
  cd "$work/src"
  export GOOS=android GOARCH=arm64 CGO_ENABLED=1 GOTOOLCHAIN=local GOWORK=off
  export CC="$ndk/bin/aarch64-linux-android23-clang"
  "${GO:-go}" build -mod=readonly -tags with_gvisor -trimpath -ldflags '-w -s -buildid=' \
    -o "$work/lib/arm64-v8a/libmihomo.so" .
)
"$ndk/bin/aarch64-linux-android23-clang" -fPIE -pie -O2 -Wall -Wextra -Werror \
  -o "$work/lib/arm64-v8a/liblauncher.so" "$lab/launcher.c"
cd "$work"
"$ndk/bin/aarch64-linux-android23-clang" -fPIE -pie -O2 -Wall -Wextra -Werror -o dns-client "$lab/dns_client.c"
"$JAVA_HOME/bin/javac" --release 8 -cp "$platform" -d classes "$lab/Probe.java" "$lab/Check.java"
"$JAVA_HOME/bin/jar" cf classes.jar -C classes .
"$bt/d8" --min-api 23 --lib "$platform" --output . classes.jar
"$bt/aapt2" link -I "$platform" --manifest "$lab/AndroidManifest.xml" --min-sdk-version 23 \
  --target-sdk-version 35 -o unsigned.apk
zip -q -r unsigned.apk lib classes.dex
"$bt/zipalign" -P 16 -f 4 unsigned.apk aligned.apk
"$JAVA_HOME/bin/keytool" -genkeypair -noprompt -keystore debug.p12 -storetype PKCS12 -storepass android \
  -keypass android -alias lab -keyalg RSA -keysize 2048 -validity 30 -dname 'CN=CLAY VPN Fixture' >/dev/null
"$bt/apksigner" sign --ks debug.p12 --ks-pass pass:android --ks-key-alias lab --out probe.apk aligned.apk
"$bt/apksigner" verify probe.apk

# The emulator reaches the loopback test server at its host alias, 10.0.2.2.
python3 "$lab/fixture.py" &
fixture_pid=$!
for _ in {1..30}; do [[ ! -s test-port ]] || break; sleep 0.1; done
port=$(cat test-port)
dns_port=$(cat dns-port)
proof=$(cat fixture-proof)
[[ "$proof" =~ ^CLAY_TUN_[0-9a-f]{24}$ ]]
"${adb[@]}" install probe.apk
installed=true
guest_client=/data/local/tmp/clay-vpn-dns-$(python3 -c 'import secrets; print(secrets.token_hex(8))')
"${adb[@]}" push dns-client "$guest_client" >/dev/null
"${adb[@]}" shell chmod 700 "$guest_client"
"${adb[@]}" shell appops set "$package" ACTIVATE_VPN allow

for protection in off deny on; do
  tag="ClayVpn$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
  "${adb[@]}" shell am instrument -w -r -e protection "$protection" -e port "$port" -e dnsPort "$dns_port" -e tag "$tag" \
    "$package/.Check" > "result-$protection.log" &
  test_pid=$!
  report=
  for _ in {1..25}; do
    report=$("${adb[@]}" logcat -d -v brief -s "$tag:I")
    if [[ "$report" == *'Tun adapter listening'* || "$report" == *'test failed'* ]]; then break; fi
    sleep 0.2
  done
  if [[ "$report" != *'Tun adapter listening'* ]]; then printf '%s\n' "$report" >&2; exit 1; fi
  current=$(routes)
  grep -F '198.51.100.42 dev tun' <<< "$current"
  grep -F '10.0.2.2 dev tun' <<< "$current"
  response=$("${adb[@]}" shell 'printf "GET /clay-proof HTTP/1.0\r\n\r\n" | toybox nc -w 3 -q 2 198.51.100.42 18080' 2>/dev/null || true)
  trace=$("${adb[@]}" logcat -d -v brief -s "$tag:I")
  case "$protection" in
    off)
      [[ "$response" != *"$proof" && "$trace" == *'match IPCIDR(10.0.2.2/32) using REJECT'* ]]
      ;;
    deny)
      [[ "$response" != *"$proof" && "$trace" == *'CLAY_PROBE_PROTECT_REJECTED'* &&
         "$trace" == *'CLAY_PROBE_PROTECT_DENIED'* && "$trace" != *'using REJECT'* ]]
      ;;
    on)
      [[ "$response" == *"$proof" && "$trace" == *'CLAY_PROBE_PROTECT_OK'* && "$trace" != *'using REJECT'* ]]
      ;;
  esac || {
      printf 'Unexpected result for socket protection=%s.\n%s\n' "$protection" "$trace" >&2
      exit 1
  }
  if [[ "$protection" == on ]]; then
    "${adb[@]}" shell -T "$guest_client" < dns-query > dns-reply
    python3 - <<'PY'
from pathlib import Path
from struct import unpack

query = Path('dns-query').read_bytes()
reply = Path('dns-reply').read_bytes()
assert len(reply) >= len(query) + 16, 'No complete DNS response from the TUN'
identifier, flags, qd, an, _, _ = unpack('!HHHHHH', reply[:12])
assert identifier == 0x5116 and flags & 0x800f == 0x8000 and (qd, an) == (1, 1)
assert reply[12:len(query)] == query[12:]
assert reply[len(query):len(query) + 16] == bytes.fromhex('c00c00010001000000000004cb007149')
print('CLAY_PROBE_DNS_UDP_PASS')
PY
  fi
  wait "$test_pid"
  test_pid=
  tr -d '\r' < "result-$protection.log" | grep -Fx 'INSTRUMENTATION_CODE: -1'
  for _ in {1..30}; do
    current=$(routes)
    if ! vpn_routes "$current"; then break; fi
    sleep 0.15
  done
  if vpn_routes "$current"; then printf 'TUN route still present after test exit.\n' >&2; exit 1; fi
  printf 'CLAY_PROBE_PROTECT_%s_PASS\n' "$protection"
done
"${adb[@]}" uninstall "$package"
installed=false
