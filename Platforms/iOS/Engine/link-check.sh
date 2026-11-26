#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || { printf 'Usage: %s macos|iphoneos|iphonesimulator BUILD_DIRECTORY\n' "$0" >&2; exit 64; }
target=$1
out=$2
root=$(cd "$(dirname "$0")" && pwd)
case "$target" in
  macos) toolchain=(--sdk macosx clang); flags=();;
  iphoneos|iphonesimulator)
    toolchain=(--sdk "$target" clang)
    triple=arm64-apple-ios16.0
    [[ "$target" != iphonesimulator ]] || triple+=-simulator
    flags=(-target "$triple" -isysroot "$(xcrun --sdk "$target" --show-sdk-path)" -fapplication-extension)
    ;;
  *) exit 64 ;;
esac
xcrun "${toolchain[@]}" ${flags[@]+"${flags[@]}"} -Wall -Wextra -Werror \
    -I "$out" "$root/abi-smoke.c" "$out/libCLAYPacketEngine.a" \
    -framework CoreFoundation -framework Security -lresolv -o "$out/abi-smoke"
