#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
android_dir="$PWD"
repo=$(cd ../.. && pwd)
with_tests=false
if [[ ${1:-} == --test && $# == 1 ]]; then
  with_tests=true
elif [[ $# != 0 ]]; then
  printf 'Usage: bash Platforms/Android/build-apk.sh [--test]\n' >&2
  exit 64
fi

: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK r30}"
: "${SWIFT_SDKS_PATH:?Set SWIFT_SDKS_PATH to the directory containing the Android Swift SDK artifact}"
: "${JAVA_HOME:?Set JAVA_HOME to a JDK 17 installation}"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
: "${sdk:?Set ANDROID_HOME to your Android SDK directory}"
swift_bin=${SWIFT_BIN:-swift}
out=${CLAY_ANDROID_APK_DIR:-$repo/.build/android-apk}
version=$(cat "$repo/VERSION")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]

version_report=$("$swift_bin" --version)
if [[ "$version_report" != *'Swift version 6.4.3 '* ]] ||
   ! grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*30\.0\.16248370[[:space:]]*$' "$ANDROID_NDK_HOME/source.properties"; then
  printf 'Swift 6.4.3 and Android NDK revision 30.0.16248370 are required.\n' >&2
  exit 1
fi
case $(uname -s) in
  Darwin) host=darwin-x86_64 ;;
  Linux) host=linux-x86_64 ;;
  *) printf 'Build host must be macOS or Linux.\n' >&2; exit 1 ;;
esac
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"
ndk="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host"
bt="$sdk/build-tools/36.0.0"
platform="$sdk/platforms/android-35/android.jar"
swift_license="$SWIFT_SDKS_PATH/swift-6.4.3-RELEASE_android.artifactbundle/swift-android/swift-resources/usr/share/swift/LICENSE.txt"
test -r "$platform"
test -r "$swift_license"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*36\.0\.0[[:space:]]*$' "$bt/source.properties"
src="$android_dir/app/src/main"
test -r "$src/java/org/clayrelay/preview/MainActivity.java"
umask 077
mkdir -p "$out"
out=$(cd "$out" && pwd)
stage=$(mktemp -d "$out/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT

flags=(--package-path "$android_dir" --scratch-path "$out/swift-build"
       --swift-sdks-path "$SWIFT_SDKS_PATH" --swift-sdk swift-6.4.3-RELEASE_android
       --triple aarch64-unknown-linux-android23 --static-swift-stdlib -c release --product CLAYAndroidBridge)
if [[ ${CLAY_SWIFTPM_NO_NESTED_SANDBOX:-0} == 1 ]]; then
  flags+=(--disable-sandbox)
fi
"$swift_bin" build "${flags[@]}"
products=$("$swift_bin" build "${flags[@]}" --show-bin-path)
lib="$stage/main/lib/arm64-v8a"
mkdir -p "$lib"
"$ndk/bin/llvm-strip" --strip-debug -o "$lib/libCLAYAndroidBridge.so" "$products/libCLAYAndroidBridge.so"
install -m 644 "$ndk/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$lib/"
"$ndk/bin/aarch64-linux-android23-clang" -shared -fPIC -O2 -fvisibility=hidden -Wall -Wextra -Werror \
  -Wl,--no-undefined,-soname,libclaypreview.so -o "$lib/libclaypreview.so" \
  "$android_dir/app/src/main/c/preview.c" -L"$lib" -lCLAYAndroidBridge
for native in "$lib"/*.so; do
  report=$("$ndk/bin/llvm-readelf" -h "$native")
  grep -q 'Machine:.*AArch64' <<< "$report"
  "$ndk/bin/llvm-readelf" -l "$native" | awk '
    $1 == "LOAD" { seen = 1; if ($NF != "0x4000" && $NF != "0x10000") bad = 1 }
    END { exit !seen || bad }
  '
done

licenses="$stage/main/assets/licenses"
mkdir -p "$licenses"
install -m 644 "$repo/LICENSE" "$licenses/CLAY.txt"
install -m 644 "$repo/Vendor/Yams/LICENSE" "$licenses/Yams.txt"
install -m 644 "$repo/Vendor/Yams/LICENSE-libyaml" "$licenses/libyaml.txt"
install -m 644 "$swift_license" "$licenses/Swift.txt"
install -m 644 "$ANDROID_NDK_HOME/NOTICE.toolchain" "$licenses/Android-NDK.txt"

key="$out/debug.p12"
if [[ ! -f "$key" ]]; then
  "$JAVA_HOME/bin/keytool" -genkeypair -noprompt -keystore "$key" -storetype PKCS12 -storepass android \
    -keypass android -alias clay-local-debug -keyalg RSA -keysize 2048 -validity 3650 \
    -dname 'CN=CLAY Local Debug,O=CLAY,C=US'
fi
finish_apk() {
  local path="$1"
  "$bt/zipalign" -P 16 -f 4 "$path/unsigned.apk" "$path/aligned.apk"
  "$bt/apksigner" sign --ks "$key" --ks-pass pass:android --ks-key-alias clay-local-debug \
    --out "$path/final.apk" "$path/aligned.apk"
  "$bt/apksigner" verify "$path/final.apk"
  "$bt/zipalign" -c -P 16 4 "$path/final.apk"
}
compile_java() {
  local path="$1" classpath="$2"
  shift 2
  mkdir -p "$path/classes"
  "$JAVA_HOME/bin/javac" --release 8 -encoding UTF-8 -classpath "$classpath" -d "$path/classes" "$@"
  "$JAVA_HOME/bin/jar" cf "$path/classes.jar" -C "$path/classes" .
  "$bt/d8" --min-api 23 --lib "$platform" --output "$path" "$path/classes.jar"
  (cd "$path" && zip -q unsigned.apk classes.dex)
}

main="$stage/main"
mkdir -p "$main/gen"
"$bt/aapt2" compile --dir "$src/res" -o "$main/res.zip"
"$bt/aapt2" link -I "$platform" --manifest "$src/AndroidManifest.xml" --min-sdk-version 23 \
  --target-sdk-version 35 --version-code 1 --version-name "$version" --java "$main/gen" \
  -A "$main/assets" -o "$main/unsigned.apk" "$main/res.zip"
compile_java "$main" "$platform" "$src/java/org/clayrelay/preview/"*.java "$main/gen/org/clayrelay/preview/R.java"
(cd "$main" && zip -q -r unsigned.apk lib)
permissions=$("$bt/aapt2" dump permissions "$main/unsigned.apk")
if grep -q 'uses-permission' <<< "$permissions"; then
  printf 'The offline APK must not declare device permissions.\n' >&2
  exit 1
fi
finish_apk "$main"

if $with_tests; then
  test_src="$android_dir/app/src/androidTest"
  test_stage="$stage/test"
  mkdir -p "$test_stage"
  "$bt/aapt2" link -I "$platform" --manifest "$test_src/AndroidManifest.xml" --min-sdk-version 23 \
    --target-sdk-version 35 -o "$test_stage/unsigned.apk"
  compile_java "$test_stage" "$platform:$main/classes.jar" "$test_src/java/org/clayrelay/preview/PreviewInstrumentation.java"
  finish_apk "$test_stage"
  mv -f "$test_stage/final.apk" "$out/CLAY-Android-arm64-test.apk"
  printf '%s\n' "$out/CLAY-Android-arm64-test.apk"
fi
mv -f "$main/final.apk" "$out/CLAY-Android-arm64-preview.apk"
printf '%s\n' "$out/CLAY-Android-arm64-preview.apk"
