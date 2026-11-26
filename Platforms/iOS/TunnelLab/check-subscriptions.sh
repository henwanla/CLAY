#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
bash scripts/swift-local.sh build -c release --product CLAYCoreChecks
builddir="$(bash scripts/swift-local.sh build -c release --show-bin-path)"
scratch="$(mktemp -d "$PWD/.build/ios-subscriptions.XXXXXX")"
trap 'rm -r "$scratch"' EXIT
awk 'index($0, "/CLAYCoreChecks.build/") == 0' "$builddir/CLAYCoreChecks.product/Objects.LinkFileList" > "$scratch/core.rsp"
options=(
  -parse-as-library -O -module-cache-path "$PWD/.build/module-cache"
  -I "$builddir/Modules" -I "$builddir/CYaml.build" -I "$PWD/Vendor/Yams/Sources/CYaml/include"
  "@$scratch/core.rsp" Platforms/iOS/TunnelLab/LabSubscriptionStore.swift
  Platforms/iOS/TunnelLab/LabSubscriptionChecks.swift -o "$scratch/check"
)
swiftc "${options[@]}"
"$scratch/check"
