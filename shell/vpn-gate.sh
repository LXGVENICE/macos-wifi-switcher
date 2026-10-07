#!/bin/sh
phase=vpn_gate
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
[ "$#" -eq 1 ] || fail 'Missing verified target context.'
# Consume the already-validated target only after verification succeeds.
# Read through the VPN field; never reread config or network settings.
load_vpn() {
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
}
load_vpn <<WIFI_TARGET_DATA
$1
WIFI_TARGET_DATA
current_run="$config_dir/current-run"
guard_run
case "$event:$vpn" in
    join:connect) printf '%s' CONNECT_SHADOWROCKET;;
    join:disconnect) printf '%s' DISCONNECT_SHADOWROCKET;;
    *) fail 'The verified target has no supported VPN action.';;
esac
