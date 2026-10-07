#!/bin/sh
phase=prepare
set -eu
export LC_ALL=C
umask 077
networksetup=/usr/sbin/networksetup
plutil=/usr/bin/plutil
fail() { printf 'Wi-Fi: %s\n' "$1" >&2; exit 1; }
single_line() {
    printf '%s\n' "$1" | /usr/bin/awk 'NR > 1 || /[[:cntrl:]]/ {exit 1} END {if (NR != 1) exit 1}'
}
# All fields come from the immutable in-memory configuration snapshot.
read_value() {
    printf '%s' "$config_xml" | "$plutil" -extract "$1" raw -expect "$2" -o - - 2>/dev/null ||
        fail "Missing or invalid field: $1 ($config)."
}
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Enable Run as Administrator for this shell action.'
[ "$#" -eq 1 ] || fail 'Missing or invalid configuration directory argument.'
config_dir=$1
single_line "$config_dir" || fail 'Configuration directory must be a single line.'
case "$config_dir" in /*) :;; *) fail 'Configuration directory must be an absolute path.';; esac
case "$config_dir" in /) :;; *) config_dir=${config_dir%/};; esac
config="$config_dir/config.json"
[ -r "$config" ] || fail "Create this Mac's configuration first: $config"
# Register once, before reading SSID or taking the network-write lock.
# A same-directory rename publishes a complete UUID; last publication wins.
current_run="$config_dir/current-run"
[ ! -d "$current_run" ] || fail 'current-run must be a file, not a directory.'
run_id=$(/usr/bin/uuidgen)
registration_file=$(/usr/bin/mktemp "$config_dir/.current-run.XXXXXX")
trap '/bin/rm -f "$registration_file"' 0
trap 'exit 1' 1 2 15
printf '%s\n' "$run_id" > "$registration_file"
/bin/mv -f "$registration_file" "$current_run"
trap - 0 1 2 15
# Read and validate the file once per invocation, before the native repeat loop.
config_xml=$("$plutil" -convert xml1 -o - "$config" 2>/dev/null) || fail 'Invalid configuration format.'
[ "$(read_value version integer)" = 3 ] || fail 'Unsupported configuration version.'
service=$(read_value networkService string)
case "$service" in ''|-*) fail 'Invalid networkService.';; esac
single_line "$service" || fail 'networkService must be a single line.'
service_order=$("$networksetup" -listnetworkserviceorder)
device=$(printf '%s\n' "$service_order" | /usr/bin/awk -v wanted="$service" '
    /^\([0-9]+\) / {name=$0; sub(/^\([0-9]+\) /,"",name); selected=(name==wanted); next}
    selected && /^\(Hardware Port: Wi-Fi, Device: [a-zA-Z0-9]+\)$/ {
        line=$0; sub(/^.*Device: /,"",line); sub(/\)$/,"",line); print line; selected=0
    }')
case "$device" in ''|*[!a-zA-Z0-9]*) fail 'networkService must identify one enabled Wi-Fi service.';; esac
printf '%s\n' WIFI_CONTEXT_V2 "$config_dir" "$run_id" "$service" "$device" "$config_xml"
