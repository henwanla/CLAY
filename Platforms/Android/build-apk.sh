#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
android_dir="$PWD"
repo=$(cd ../.. && pwd)
with_tests=false
relay_archive=
vpn_archive=
while [[ $# != 0 ]]; do
  case $1 in
    --test) with_tests=true; shift ;;
    --relay) [[ $# -ge 2 ]]; relay_archive=$2; shift 2 ;;
    --vpn) [[ $# -ge 2 ]]; vpn_archive=$2; shift 2 ;;
    *) printf 'Usage: bash Platforms/Android/build-apk.sh [--test] [--relay VERIFIED_ANDROID_MIHOMO_GZ | --vpn VERIFIED_MIHOMO_SOURCE_TGZ]\n' >&2; exit 64 ;;
  esac
done

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
flavor=preview
app_id=org.clayrelay.preview
manifest="$src/AndroidManifest.xml"
engine_sha=
min_api=23
[[ -z "$relay_archive" || -z "$vpn_archive" ]]
if [[ -n "$vpn_archive" ]]; then
  flavor=vpn
  app_id=org.clayrelay.vpn
  manifest="$android_dir/app/src/vpn/AndroidManifest.xml"
  min_api=26
fi
if [[ -n "$relay_archive" ]]; then
  flavor=relay
  app_id=org.clayrelay.relay
  manifest="$android_dir/app/src/relay/AndroidManifest.xml"
  [[ $(shasum -a 256 < "$relay_archive" | cut -d ' ' -f1) == 48a71fc6a68e2909587176e0ab7185d8f2fac298fa96ccdacf30ea86ab2359b5 ]]
  engine_sha=1369bebba2b7a6fe971fe6ece0cb5aa18c81e49c89dd8340f43e5e7583d3da36
fi

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
if [[ "$flavor" == relay ]]; then
  gzip -dc "$relay_archive" > "$lib/libclay_mihomo.so"
  [[ $(shasum -a 256 < "$lib/libclay_mihomo.so" | cut -d ' ' -f1) == "$engine_sha" ]]
  "$ndk/bin/aarch64-linux-android23-clang" -fPIE -pie -O2 -Wall -Wextra -Werror \
    -o "$lib/libclay_launcher.so" "$src/c/relay-launcher.c"
fi
if [[ "$flavor" == vpn ]]; then
  bash "$android_dir/build-vpn-engine.sh" "$vpn_archive" "$lib/libclay_mihomo.so"
  engine_sha=$(shasum -a 256 < "$lib/libclay_mihomo.so" | cut -d ' ' -f1)
  "$ndk/bin/aarch64-linux-android23-clang" -DCLAY_REQUIRE_PROTECTION -fPIE -pie -O2 -Wall -Wextra -Werror \
    -o "$lib/libclay_launcher.so" "$android_dir/vpn-lab/launcher.c"
fi
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
if [[ "$flavor" == relay ]]; then
  printf '%s\n' 'Mihomo v1.19.34: unmodified upstream Android arm64 executable.' \
    'GPL-3.0; source and license: https://github.com/MetaCubeX/mihomo/tree/v1.19.34' > "$licenses/Mihomo.txt"
fi

if [[ "$flavor" == vpn ]]; then
  tar -xOf "$vpn_archive" mihomo-1.19.34/LICENSE > "$licenses/Mihomo-LICENSE.txt"
  printf '%s\n' 'Mihomo v1.19.34 with CLAY Android TUN and socket protection changes.' \
    'Corresponding source, patches and build recipe: Platforms/Android in the source checkout used to build this APK.' > "$licenses/Mihomo.txt"
fi

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
  local -a dependencies=()
  shift 2
  mkdir -p "$path/classes"
  "$JAVA_HOME/bin/javac" --release 8 -encoding UTF-8 -classpath "$classpath" -d "$path/classes" "$@"
  "$JAVA_HOME/bin/jar" cf "$path/classes.jar" -C "$path/classes" .
  if [[ "$classpath" != "$platform" ]]; then
    dependencies=(--classpath "${classpath#"$platform":}")
  fi
  "$bt/d8" --min-api "$min_api" --lib "$platform" "${dependencies[@]+"${dependencies[@]}"}" --output "$path" "$path/classes.jar"
  (cd "$path" && zip -q unsigned.apk classes.dex)
}

main="$stage/main"
mkdir -p "$main/gen"
"$bt/aapt2" compile --dir "$src/res" -o "$main/res.zip"
"$bt/aapt2" link -I "$platform" --manifest "$manifest" --min-sdk-version "$min_api" \
  --target-sdk-version 35 --version-code 1 --version-name "$version" --java "$main/gen" --custom-package org.clayrelay.preview \
  -A "$main/assets" -o "$main/unsigned.apk" "$main/res.zip"
cat > "$main/gen/org/clayrelay/preview/BuildFlavor.java" <<JAVA
package org.clayrelay.preview;
final class BuildFlavor {
    static final boolean RELAY = $(if [[ "$flavor" == relay ]]; then printf true; else printf false; fi);
    static final boolean VPN = $(if [[ "$flavor" == vpn ]]; then printf true; else printf false; fi);
    static final String ENGINE_SHA256 = "$engine_sha";
}
JAVA
compile_java "$main" "$platform" "$src/java/org/clayrelay/preview/"*.java "$main/gen/org/clayrelay/preview/"*.java
(cd "$main" && zip -q -r unsigned.apk lib)
permissions=$("$bt/aapt2" dump permissions "$main/unsigned.apk")
if [[ "$flavor" == relay ]]; then
  [[ $(grep '^uses-permission' <<< "$permissions") == "uses-permission: name='android.permission.INTERNET'" ]]
elif [[ "$flavor" == vpn ]]; then
  expected=$(printf '%s\n' android.permission.{FOREGROUND_SERVICE,FOREGROUND_SERVICE_SYSTEM_EXEMPTED,INTERNET,POST_NOTIFICATIONS} | sort)
  actual=$(sed -n "s/^uses-permission: name='\([^']*\)'$/\1/p" <<< "$permissions" | sort)
  [[ "$actual" == "$expected" && $(grep -c '^uses-permission' <<< "$permissions") == 4 ]]
elif grep -q 'uses-permission' <<< "$permissions"; then
  printf 'The offline APK must not declare device permissions.\n' >&2
  exit 1
fi
finish_apk "$main"

if $with_tests; then
  test_src="$android_dir/app/src/androidTest"
  test_stage="$stage/test"
  mkdir -p "$test_stage"
  "$bt/aapt2" link -I "$platform" --manifest "$test_src/AndroidManifest.xml" --min-sdk-version "$min_api" \
    --target-sdk-version 35 --rename-manifest-package "$app_id.tests" \
    --rename-instrumentation-target-package "$app_id" -o "$test_stage/unsigned.apk"
  compile_java "$test_stage" "$platform:$main/classes.jar" "$test_src/java/org/clayrelay/preview/"*.java
  finish_apk "$test_stage"
  test_name=test
  [[ "$flavor" == preview ]] || test_name="$flavor-test"
  mv -f "$test_stage/final.apk" "$out/CLAY-Android-arm64-$test_name.apk"
  printf '%s\n' "$out/CLAY-Android-arm64-$test_name.apk"
  if [[ "$flavor" == vpn ]]; then
    fixture="$test_src/vpn-revoker"
    fixture_stage="$stage/vpn-revoker"
    mkdir -p "$fixture_stage"
    "$bt/aapt2" link -I "$platform" --manifest "$fixture/AndroidManifest.xml" --min-sdk-version "$min_api" \
      --target-sdk-version 35 -o "$fixture_stage/unsigned.apk"
    compile_java "$fixture_stage" "$platform" "$fixture/Revoker.java"
    fixture_permissions=$("$bt/aapt2" dump permissions "$fixture_stage/unsigned.apk")
    ! grep -q '^uses-permission' <<< "$fixture_permissions" || exit 1
    finish_apk "$fixture_stage"
    mv -f "$fixture_stage/final.apk" "$out/CLAY-Android-arm64-vpn-revoker.apk"
    printf '%s\n' "$out/CLAY-Android-arm64-vpn-revoker.apk"
  fi
fi
mv -f "$main/final.apk" "$out/CLAY-Android-arm64-$flavor.apk"
printf '%s\n' "$out/CLAY-Android-arm64-$flavor.apk"
