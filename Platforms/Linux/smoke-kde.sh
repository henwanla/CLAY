#!/bin/bash
# Native KDE config and libproxy checks without an actual user's desktop.
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -m 700 "$scratch/home" "$scratch/defaults" "$scratch/config" "$scratch/state" "$scratch/runtime" "$scratch/bin"
install -m 700 "$1" "$scratch/bin/clay-portable"
install -m 700 "$2" "$scratch/bin/clay-kde-settings"
HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/config" XDG_CONFIG_DIRS="$scratch/defaults" \
  XDG_STATE_HOME="$scratch/state" XDG_RUNTIME_DIR="$scratch/runtime" XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6 \
  CLAY_KDE_FIXTURE="$scratch" dbus-run-session -- xvfb-run -a /usr/bin/python3 -B Platforms/Linux/smoke-kde.py "$scratch/bin/clay-portable"
