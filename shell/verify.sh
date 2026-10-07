#!/bin/sh
phase=verify
set -eu
export LC_ALL=C
umask 077
networksetup=/usr/sbin/networksetup
ifconfig=/sbin/ifconfig
fail() { printf 'Wi-Fi: %s\n' "$1" >&2; exit 1; }
retry() { printf '%s' RETRY; exit 0; }
read_line() { IFS= read -r "$1" || fail 'Incomplete shortcut context.'; }
stale() { printf '%s' STALE; exit 0; }
# A cooperative cancellation check: no config parsing, lock or subprocess.
guard_run() {
    IFS= read -r latest_run < "$current_run" || fail 'Cannot read the latest Wi-Fi task identifier.'
    [ "$latest_run" = "$run_id" ] || stale
}
single_line() {
    printf '%s\n' "$1" | /usr/bin/awk 'NR > 1 || /[[:cntrl:]]/ {exit 1} END {if (NR != 1) exit 1}'
}
link_state() {
    raw_link=$("$ifconfig" "$device") || fail "Cannot read Wi-Fi link state."
    state=$(printf '%s\n' "$raw_link" | /usr/bin/awk '/^[[:space:]]*status:/ {print $2}')
    case "$state" in active|inactive) printf '%s\n' "$state";; *) fail "Unknown Wi-Fi link state; stopped without further changes.";; esac
}
guard_state() {
    current_state=$(link_state)
    guard_run
    [ "$current_state" = "$observed_state" ] || retry
}

matches_ipv4() {
    if [ "$mode" = auto ]; then
        printf '%s\n' "$1" | /usr/bin/grep -Fxq 'DHCP Configuration'
    else
        printf '%s\n' "$1" | /usr/bin/grep -Fxq 'Manual Configuration' &&
        printf '%s\n' "$1" | /usr/bin/grep -Fxq -- "IP address: $ip" &&
        printf '%s\n' "$1" | /usr/bin/grep -Fxq -- "Subnet mask: $subnet" &&
        printf '%s\n' "$1" | /usr/bin/grep -Fxq -- "Router: $router"
    fi
}
matches_dns() {
    if [ "$mode" = auto ]; then
        [ "$1" = "There aren't any DNS Servers set on $service." ]
    else
        [ "$1" = "$expected_dns" ]
    fi
}
matches_ipv6() {
    printf '%s\n' "$1" | /usr/bin/grep -Fxq 'IPv6: Automatic'
}
matches_profile() {
    matches_ipv4 "$1" && matches_dns "$2" && matches_ipv6 "$1"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Enable Run as Administrator for this shell action.'
case "$#" in 1|2) :;; *) fail 'Missing or invalid verify arguments.';; esac
fresh_ssid=${2-}
single_line "$fresh_ssid" || fail 'Wi-Fi name contains unsupported control characters.'
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
lock="$config_dir/apply.lock"
current_run="$config_dir/current-run"
expected_dns=$(printf '%s' "$dns_line" | /usr/bin/tr ',' '\n')
# Registration is independent. The first probe has drained any earlier write
# before native SSID capture. Lock contention never consumes a state attempt.
guard_run
exec 9>"$lock"
/usr/bin/lockf -s 9 || fail 'Cannot acquire the local network settings lock.'
# A newer task may have registered while this process waited for the lock.
guard_run
# A different native SSID requires a new attempt and profile selection.
[ "$fresh_ssid" = "$ssid" ] || retry
observed_state=$(link_state)
case "$event:$observed_state" in join:active|disconnect:inactive) :;; *) retry;; esac
# The only post-apply readback. No configuration file reread or profile revalidation.
info=$("$networksetup" -getinfo "$service")
dns=$("$networksetup" -getdnsservers "$service")
guard_state
matches_profile "$info" "$dns" || retry
case "$event:$vpn" in
    join:connect|join:disconnect) printf '%s' APPLY_SHADOWROCKET;;
    *) printf 'OK: event=%s profile=%s mode=%s verified=yes vpn=keep\n' "$event" "$profile" "$mode";;
esac
