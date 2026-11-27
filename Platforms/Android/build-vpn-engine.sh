#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || { printf 'Usage: %s MIHOMO_SOURCE_TGZ OUTPUT_SO\n' "$0" >&2; exit 64; }
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK r30}"
archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
lab=$(cd "$(dirname "$0")/vpn-lab" && pwd)
expected=e3284a44f1052f1c454c90d418faa244516c2470bf232b455ea18fc4f5fa6028
[[ $(shasum -a 256 < "$archive" | cut -d ' ' -f1) == "$expected" ]]
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*30\.0\.16248370[[:space:]]*$' "$ANDROID_NDK_HOME/source.properties"
case $(uname -s) in
  Darwin) host=darwin-x86_64 ;;
  Linux) host=linux-x86_64 ;;
  *) exit 64 ;;
esac
export GOOS=android GOARCH=arm64 CGO_ENABLED=1 GOTOOLCHAIN=local GOWORK=off GOFLAGS= GOENV=off
export CC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin/aarch64-linux-android23-clang"
go_bin=${GO:-go}
[[ $("$go_bin" version) == 'go version go1.24.3 '* ]]
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/clay-vpn-engine.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
tar -xzf "$archive" --strip-components=1
git apply --unidiff-zero "$lab/external-tun.patch"
cp "$lab/protect_android.go" clay_protect_android.go
cp "$lab/dns_tcp_retry.go" tunnel/clay_dns_tcp_retry.go
"$go_bin" build -mod=readonly -tags with_gvisor -trimpath \
  -ldflags '-w -s -buildid= -X main.clayRequireProtection=1' -o "$out" .
