#!/bin/bash
# An isolated home for dconf and D-Bus. Never exercise writes in a user's session.
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -m 700 "$scratch/config" "$scratch/state" "$scratch/runtime"
XDG_CONFIG_HOME="$scratch/config" XDG_STATE_HOME="$scratch/state" XDG_RUNTIME_DIR="$scratch/runtime" \
  XDG_CURRENT_DESKTOP=GNOME GSETTINGS_BACKEND=dconf CLAY_GNOME_FIXTURE="$scratch" \
  dbus-run-session -- xvfb-run -a /usr/bin/python3 -B Platforms/Linux/smoke-desktop.py "$1" --gnome-fixture
