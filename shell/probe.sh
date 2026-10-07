#!/bin/sh
phase=probe
set -eu
export LC_ALL=C
umask 077
ifconfig=/sbin/ifconfig
fail() { printf 'Wi-Fi: %s\n' "$1" >&2; exit 1; }
read_line() { IFS= read -r "$1" || fail 'Incomplete shortcut context.'; }
stale() { printf '%s' STALE; exit 0; }
# A cooperative cancellation check: no config parsing, lock or subprocess.
guard_run() {
    IFS= read -r latest_run < "$current_run" || fail 'Cannot read the latest Wi-Fi task identifier.'
    [ "$latest_run" = "$run_id" ] || stale
}
link_state() {
    raw_link=$("$ifconfig" "$device") || fail "Cannot read Wi-Fi link state."
    state=$(printf '%s\n' "$raw_link" | /usr/bin/awk '/^[[:space:]]*status:/ {print $2}')
    case "$state" in active|inactive) printf '%s\n' "$state";; *) fail "Unknown Wi-Fi link state; stopped without further changes.";; esac
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Enable Run as Administrator for this shell action.'
[ "$#" -eq 1 ] || fail 'Missing or invalid probe arguments.'
# The apply action supplies an already-validated target for this attempt.
case "$1" in RETRY|STALE) printf '%s' "$1"; exit 0;; esac
load_target() {
    read_line record_kind
    [ "$record_kind" = WIFI_TARGET_V2 ] || fail 'Invalid shortcut target context.'
    read_line config_dir
    read_line run_id
    read_line service
    read_line device
    read_line event
    read_line ssid
    read_line profile
    read_line mode
    read_line vpn
    read_line ip
    read_line subnet
    read_line router
    read_line dns_line
    read_line record_end
    [ "$record_end" = WIFI_TARGET_END_V2 ] || fail 'Incomplete shortcut target context.'
}
load_target <<WIFI_TARGET_DATA
$1
WIFI_TARGET_DATA
current_run="$config_dir/current-run"
guard_run
probe_state=$(link_state)
if [ "$probe_state" = active ]; then printf '%s' CONNECTED; else printf '%s' DISCONNECTED; fi
