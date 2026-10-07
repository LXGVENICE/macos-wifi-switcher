#!/bin/sh
phase=final_error
set -eu
export LC_ALL=C
fail() { printf 'Wi-Fi: %s\n' "$1" >&2; exit 1; }
read_line() { IFS= read -r "$1" || fail 'Incomplete shortcut context.'; }
stale() { printf '%s' STALE; exit 0; }
# A cooperative cancellation check: no config parsing, lock or subprocess.
guard_run() {
    IFS= read -r latest_run < "$current_run" || fail 'Cannot read the latest Wi-Fi task identifier.'
    [ "$latest_run" = "$run_id" ] || stale
}
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Enable Run as Administrator for this shell action.'
[ "$#" -eq 1 ] || fail 'Missing task context.'
# Only the registration header is needed; never reread config or network settings.
load_run() {
    read_line record_kind
    [ "$record_kind" = WIFI_CONTEXT_V2 ] || fail 'Invalid shortcut configuration context.'
    read_line config_dir
    read_line run_id
}
load_run <<WIFI_RUN_DATA
$1
WIFI_RUN_DATA
current_run="$config_dir/current-run"
guard_run
printf '%s\n' 'Wi-Fi: network state is still changing, Wi-Fi name is unavailable, or the requested settings could not be verified. No VPN action was performed; retry after the connection settles.' >&2
exit 1
