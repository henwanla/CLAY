#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { printf 'Usage: %s MIHOMO_SOURCE_TGZ host-test|host-race|macos|iphoneos|iphonesimulator OUTPUT_DIRECTORY\n' "$0" >&2; exit 64; }
source=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
target=$2
mkdir -p "$3"
out=$(cd "$3" && pwd)
engine=$(cd "$(dirname "$0")" && pwd)
expected=e3284a44f1052f1c454c90d418faa244516c2470bf232b455ea18fc4f5fa6028
[[ $(shasum -a 256 < "$source" | cut -d ' ' -f1) == "$expected" ]]
export GOTOOLCHAIN=local GOWORK=off GOFLAGS= GOENV=off CGO_ENABLED=1
compiler=${GO:-go}
[[ $("$compiler" version) == 'go version go1.24.3 '* ]]
case "$target" in
  host-test|host-race|macos) export GOOS=darwin GOARCH=$("$compiler" env GOHOSTARCH);;
  iphoneos|iphonesimulator)
    export GOOS=ios GOARCH=arm64
    sdk=$(xcrun --sdk "$target" --show-sdk-path)
    clang=$(xcrun --sdk "$target" --find clang)
    triple=arm64-apple-ios16.0
    [[ "$target" != iphonesimulator ]] || triple+=-simulator
    ;;
  *) exit 64 ;;
esac
if [[ "$target" == host-test || "$target" == host-race ]]; then
  repo=$(cd "$engine/../../.." && pwd)
  bash "$repo/scripts/swift-local.sh" build -c release --product CLAYCoreChecks
  swift_bin=$(bash "$repo/scripts/swift-local.sh" build -c release --show-bin-path)
  export CLAY_PACKET_FIXTURE_IMPORTER="$swift_bin/CLAYCoreChecks"
fi
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/clay-ios-engine.XXXXXX")
trap 'rm -rf "$work"' EXIT
if [[ "$target" == iphone* ]]; then
  cat > "$work/ios-clang" <<WRAPPER
#!/usr/bin/env bash
exec "$clang" -target "$triple" -isysroot "$sdk" "\$@"
WRAPPER
  chmod 700 "$work/ios-clang"
  export CC="$work/ios-clang"
fi
mkdir "$work/mihomo"
cd "$work/mihomo"
tar -xzf "$source" --strip-components=1
mkdir clay_packet_engine
cp "$engine"/*.go clay_packet_engine/
if [[ "$target" == host-test ]]; then
  "$compiler" test -mod=readonly -tags with_gvisor -count=1 -timeout=30s -v ./clay_packet_engine
elif [[ "$target" == host-race ]]; then
  "$compiler" test -mod=readonly -tags with_gvisor -race -count=2 -timeout=90s -v \
    -run '^(TestLab(IPv6)?SwitchClosesActiveTCP|TestLabTuicPacketLifetime|TestImportedProtocols)$/^lab-live-switch-across-protocols$' ./clay_packet_engine
else
  "$compiler" build -mod=readonly -tags with_gvisor -trimpath -buildmode=c-archive \
    -ldflags '-w -s -buildid=' -o "$out/libCLAYPacketEngine.a" ./clay_packet_engine
fi
