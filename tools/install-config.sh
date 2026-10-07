#!/bin/sh
# Copy the fictional example. Never change network settings or overwrite a config.
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${1-/Users/Shared/WiFiSwitchConfig}
[ "$#" -le 1 ] || { printf '%s\n' 'Pass at most one configuration directory.' >&2; exit 1; }
case "$destination" in /*) :;; *) printf '%s\n' 'Use an absolute directory path.' >&2; exit 1;; esac
if [ -e "$destination/config.json" ]; then
    printf 'Kept existing configuration: %s/config.json\n' "$destination"
    exit 0
fi
mkdir -p "$destination"
chmod 700 "$destination"
(set -C; cat "$root/config.example.json" > "$destination/config.json")
printf 'Created: %s/config.json\n' "$destination"
printf '%s\n' 'Replace the fictional SSIDs and addresses before enabling the automation.'
