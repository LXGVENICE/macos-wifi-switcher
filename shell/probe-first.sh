#!/bin/sh
phase=probe_first
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
[ "$#" -eq 2 ] || fail 'Missing or invalid probe arguments.'
attempt=$2
case "$attempt" in 1|2|3) :;; *) fail 'Missing or invalid native Repeat Index.';; esac
# This record is data from the prepare action, never executable shell code.
load_context() {
    read_line record_kind
    [ "$record_kind" = WIFI_CONTEXT_V2 ] || fail 'Invalid shortcut configuration context.'
    read_line config_dir
    read_line run_id
    read_line service
    read_line device
}
load_context <<WIFI_CONTEXT_DATA
$1
WIFI_CONTEXT_DATA
current_run="$config_dir/current-run"
guard_run
wait_for_network=no
if [ "$attempt" -eq 1 ]; then
    # Drain the previous writer once, before native SSID capture. This barrier
    # uses the existing lock, adds no retry loop, and is released in this action.
    lock="$config_dir/apply.lock"
    exec 9>"$lock"
    /usr/bin/lockf -s 9 || fail 'Cannot wait for the previous network update.'
    guard_run
    exec 9>&-
    probe_state=$(link_state)
    [ "$probe_state" != inactive ] || wait_for_network=yes
else
    # Retries already wait unconditionally; an earlier link read is unused.
    wait_for_network=yes
fi
if [ "$wait_for_network" = yes ]; then
    /bin/sleep 1
    guard_run
    probe_state=$(link_state)
fi
if [ "$probe_state" = active ]; then printf '%s' CONNECTED; else printf '%s' DISCONNECTED; fi
