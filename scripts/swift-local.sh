#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/{module-cache,pm-cache,pm-config,pm-security}
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
action="$1"
shift
exec swift "$action" --disable-sandbox --manifest-cache none --cache-path .build/pm-cache --config-path .build/pm-config --security-path .build/pm-security -Xcc "-fmodules-cache-path=$CLANG_MODULE_CACHE_PATH" "$@"
