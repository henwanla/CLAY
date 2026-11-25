#!/usr/bin/env bash
set -euo pipefail

# Swift 6.4.3 with its matching Android SDK and Google Android NDK r30.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SWIFT_BIN=${SWIFT_BIN:-swift}
BUILD_DIR=${CLAY_ANDROID_BUILD_DIR:-$ROOT/.build/android-arm64}
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to the verified Android NDK r30 directory}"

VERSION=$("$SWIFT_BIN" --version)
if [[ "$VERSION" != *'Swift version 6.4.3 '* ]]; then
  printf 'Swift 6.4.3 is required. Detected:\n%s\n' "$VERSION" >&2
  exit 1
fi
if ! grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*30\.0\.16248370[[:space:]]*$' "$ANDROID_NDK_HOME/source.properties"; then
  printf 'Expected Android NDK revision 30.0.16248370.\n' >&2
  exit 1
fi

case $(uname -s) in
  Darwin) host=darwin-x86_64 ;;
  Linux) host=linux-x86_64 ;;
  *) printf 'Build host must be macOS or Linux.\n' >&2; exit 1 ;;
esac
ndk="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host"
test -x "$ndk/bin/llvm-readelf"
test -f "$ndk/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"

flags=(--package-path "$ROOT" --scratch-path "$BUILD_DIR")
if [[ ${CLAY_SWIFTPM_NO_NESTED_SANDBOX:-0} == 1 ]]; then
  flags+=(--disable-sandbox)
fi
if [[ -n ${SWIFT_SDKS_PATH:-} ]]; then
  flags+=(--swift-sdks-path "$SWIFT_SDKS_PATH")
fi
flags+=(--swift-sdk swift-6.4.3-RELEASE_android --triple aarch64-unknown-linux-android23
        --static-swift-stdlib -c release --product clay-portable)
"$SWIFT_BIN" build "${flags[@]}"
products=$("$SWIFT_BIN" build "${flags[@]}" --show-bin-path)
test -x "$products/clay-portable"
report=$("$ndk/bin/llvm-readelf" --file-header --program-headers "$products/clay-portable")
grep -q 'Machine:.*AArch64' <<< "$report"
grep -q 'Requesting program interpreter: /system/bin/linker64' <<< "$report"
printf 'Android arm64 executable: %s\n' "$products/clay-portable"
printf 'Matching runtime: %s\n' "$ndk/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
