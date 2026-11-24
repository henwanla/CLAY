#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then
  printf '%s\n' 'Usage: bash scripts/smoke-workspace.sh PATH_TO_TEST_MIHOMO' >&2
  exit 64
fi
scripts/swift-local.sh build -c release
builddir="$(scripts/swift-local.sh build -c release --show-bin-path)"
scratch="$(mktemp -d "$PWD/.build/workspace-checks.XXXXXX")"
trap 'rm -r "$scratch"' EXIT
# Reuse the production core's link inputs, including its C dependencies.
awk 'index($0, "/CLAYCoreChecks.build/") == 0' "$builddir/CLAYCoreChecks.product/Objects.LinkFileList" > "$scratch/core.rsp"
imports=(-I "$builddir/Modules")
if [[ -d "$builddir/CYaml.build" ]]; then
  imports+=(-I "$builddir/CYaml.build" -I "$PWD/Vendor/Yams/Sources/CYaml/include")
fi
swiftc -parse-as-library -O -module-name CLAYWorkspaceChecks -module-cache-path "$PWD/.build/module-cache" \
  -target "$(uname -m)-apple-macosx13.0" "${imports[@]}" "@$scratch/core.rsp" \
  Sources/CLAY/Workspace.swift Sources/CLAY/Subscriptions.swift Sources/CLAY/PACControl.swift \
  Tests/CLAYWorkspaceChecks/WorkspaceChecks.swift -o "$scratch/CLAYWorkspaceChecks"
python3 scripts/smoke-subscriptions.py "$scratch/CLAYWorkspaceChecks" --mihomo "$1"
