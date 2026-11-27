#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/mihomo-macos.sh
version="$(cat VERSION)"
archive="CLAY-$version-macos-arm64.zip"
(cd dist/release && shasum -a 256 -c "$archive.sha256")
scratch="$(mktemp -d)"
trap 'rm -r "$scratch"' EXIT
/usr/bin/ditto -x -k "dist/release/$archive" "$scratch"
app="$scratch/CLAY.app"
plist="$app/Contents/Info.plist"
embedded="$app/Contents/Resources/Mihomo"
engine="$embedded/mihomo"
/usr/bin/codesign --verify --strict "$app"
[[ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/CLAY")" == arm64 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CLAYUseAdjacentMihomo' "$plist")" == false ]]
[[ "$(/usr/bin/lipo -archs "$engine")" == arm64 && -x "$engine" ]]
check_mihomo_sha "$mihomo_binary_sha" "$engine"
source_archive="$scratch/Sources/mihomo-$mihomo_version-source.tar.gz"
check_mihomo_sha "$mihomo_source_sha" "$source_archive"
tar -xOzf "$source_archive" "mihomo-$mihomo_commit/LICENSE" | cmp - "$embedded/COPYING.txt"
test -s "$embedded/UPSTREAM.txt"
for notice in CLAY Yams libyaml; do
  test -s "$app/Contents/Resources/LICENSE-$notice.txt"
done
geo="$app/Contents/Resources/GeoIP"
test -s "$geo/LICENSE.txt" && test -s "$geo/README.md"
(cd "$geo" && printf '%s\n' 'd217d3e3f8b1b5c3a981dc912ec786360a33bcdc397ac1187b8e3ab1b54803ce  cn.dat' | shasum -a 256 -c)
python3 scripts/strip-screenshot-metadata.py --check "$scratch"/docs/screenshots/*.png
# Run the default engine selection, fingerprint rejection and loopback routing
# checks with the executable extracted from the public App, without opening it.
bash scripts/smoke-workspace.sh "$engine"
