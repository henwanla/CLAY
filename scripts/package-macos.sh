#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
public=false
if [[ $# == 1 && "$1" == --public ]]; then
  public=true
elif [[ $# == 2 ]]; then
  engine="$1"
  license="$2"
  expected=a55a9073f9b7b1fa596a82c034d2dae3407ec34732102b6e42c5513ce3033f34
  actual="$(shasum -a 256 < "$engine" | cut -d ' ' -f 1)"
  [[ "$actual" == "$expected" && -s "$license" ]] || { echo 'Expected the pinned macOS arm64 Mihomo v1.19.34 binary and its license.' >&2; exit 1; }
else
  echo 'Usage: scripts/package-macos.sh --public | PATH_TO_VERIFIED_MIHOMO PATH_TO_MIHOMO_LICENSE' >&2
  exit 64
fi
version="$(cat VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$(uname -m)" == arm64 ]] || { echo 'A numeric VERSION and Apple silicon build host are required.' >&2; exit 1; }
build_number=4
scripts/swift-local.sh build -c release
builddir="$(scripts/swift-local.sh build -c release --show-bin-path)"
stage="$(mktemp -d "$root/.build/package.XXXXXX")"
trap 'rm -r "$stage"' EXIT
app="$stage/CLAY.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$root/dist"
install -m 755 "$builddir/CLAY" "$app/Contents/MacOS/CLAY"
install -m 644 Vendor/Yams/LICENSE "$app/Contents/Resources/LICENSE-Yams.txt"
install -m 644 Vendor/Yams/LICENSE-libyaml "$app/Contents/Resources/LICENSE-libyaml.txt"
install -m 644 LICENSE "$app/Contents/Resources/LICENSE-CLAY.txt"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CLAY</string>
<key>CFBundleName</key><string>CLAY</string>
<key>CFBundleDisplayName</key><string>CLAY</string>
<key>CFBundleIdentifier</key><string>local.clay.desktop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CLAYUseAdjacentMihomo</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict>
  <key>NSExceptionDomains</key><dict>
    <key>127.0.0.1</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    <key>::1</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    <key>localhost</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
  </dict>
</dict>
<key>CFBundleIconFile</key><string>CLAY.icns</string>
</dict></plist>
PLIST
install -m 644 Resources/CLAY.icns "$app/Contents/Resources/CLAY.icns"
if ! $public; then
  # Keep the separately licensed engine with the app when it is moved or installed.
  embedded="$app/Contents/Resources/Mihomo"
  mkdir -p "$embedded"
  install -m 755 "$engine" "$embedded/mihomo"
  install -m 644 "$license" "$embedded/COPYING.txt"
  printf '%s\n' 'Mihomo v1.19.34 (unmodified upstream macOS arm64 executable)' 'GNU GPL version 3; source and build instructions: https://github.com/MetaCubeX/mihomo/tree/v1.19.34' > "$embedded/UPSTREAM.txt"
  [[ "$(shasum -a 256 < "$embedded/mihomo" | cut -d ' ' -f 1)" == "$expected" ]]
fi
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
[[ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/CLAY")" == arm64 ]]
if $public; then
  archive="CLAY-$version-macos-arm64.zip"
  target="$root/dist/release"
  mkdir -p "$target" "$stage/content"
  mv "$app" "$stage/content/"
  install -m 644 README.md README.en.md LICENSE CHANGELOG.md "$stage/content/"
  (cd "$stage/content" && /usr/bin/zip -q -X -r "$stage/$archive" .)
  mv -f "$stage/$archive" "$target/$archive"
  (cd "$target" && shasum -a 256 "$archive" > "$archive.sha256")
  printf '%s\n' "$target/$archive" "$target/$archive.sha256"
else
  target="$root/dist"
  mkdir -p "$target/Dependencies" "$target/docs"
  [[ "$engine" -ef "$target/Dependencies/mihomo" ]] || install -m 755 "$engine" "$target/Dependencies/mihomo"
  [[ "$license" -ef "$target/Dependencies/COPYING-Mihomo.txt" ]] || install -m 644 "$license" "$target/Dependencies/COPYING-Mihomo.txt"
  install -m 644 Vendor/Yams/LICENSE "$target/Dependencies/LICENSE-Yams.txt"
  install -m 644 Vendor/Yams/LICENSE-libyaml "$target/Dependencies/LICENSE-libyaml.txt"
  printf '%s\n'     'Mihomo v1.19.34 (upstream macOS arm64 release, unmodified)'     'GNU GPL version 3; source and build instructions: https://github.com/MetaCubeX/mihomo/tree/v1.19.34'     'libyaml (MIT), the CYaml C sources from Yams 6.1.0 (MIT): https://github.com/jpsim/Yams/tree/6.1.0/Sources/CYaml'     > "$target/Dependencies/UPSTREAM.txt"
  install -m 644 README.md "$target/使用手册.md"
  install -m 644 README.md README.en.md CHANGELOG.md LICENSE "$target/"
  install -m 644 docs/*.md "$target/docs/"
  if [[ -e "$target/CLAY.app" ]]; then mv "$target/CLAY.app" "$stage/previous.app"; fi
  mv "$app" "$target/CLAY.app"
  printf '%s\n' "$target/CLAY.app"
fi
