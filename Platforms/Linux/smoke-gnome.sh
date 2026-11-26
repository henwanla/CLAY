#!/bin/bash
# An isolated home for dconf and D-Bus. Never exercise writes in a user's session.
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -m 700 "$scratch/home" "$scratch/data" "$scratch/config" "$scratch/state" "$scratch/runtime"
printf 'user-db:user\n' > "$scratch/dconf-profile"
HOME="$scratch/home" XDG_DATA_HOME="$scratch/data" XDG_CONFIG_HOME="$scratch/config" XDG_STATE_HOME="$scratch/state" XDG_RUNTIME_DIR="$scratch/runtime" \
  XDG_CURRENT_DESKTOP=GNOME GSETTINGS_BACKEND=dconf DCONF_PROFILE="$scratch/dconf-profile" CLAY_GNOME_FIXTURE="$scratch" \
  dbus-run-session -- xvfb-run -a bash -euo pipefail -c '
    unset GNOME_KEYRING_CONTROL
    printf %s clay-temporary-test-keyring | timeout 15s gnome-keyring-daemon --unlock --components=secrets >/dev/null
    /usr/bin/python3 -B Platforms/Linux/smoke-subscriptions.py "$1" --secret-service
    /usr/bin/python3 -B Platforms/Linux/smoke-desktop.py "$1" --gnome-fixture
  ' clay-gnome-tests "$1"
