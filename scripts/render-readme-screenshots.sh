#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
scratch="$(mktemp -d "$PWD/.build/doc-shots.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
bash scripts/swift-local.sh build -c release --scratch-path "$scratch" --product CLAY \
  -Xswiftc -enable-testing -Xswiftc -DCLAY_DOCUMENTATION
bindir="$(bash scripts/swift-local.sh build -c release --scratch-path "$scratch" --show-bin-path)"
TZ=UTC "$bindir/CLAY" "$PWD/docs/screenshots"
