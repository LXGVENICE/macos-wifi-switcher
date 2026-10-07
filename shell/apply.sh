#!/bin/sh
phase=apply
set -eu
export LC_ALL=C
umask 077
networksetup=/usr/sbin/networksetup
ifconfig=/sbin/ifconfig
plutil=/usr/bin/plutil
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
valid_ipv4() {
    printf '%s\n' "$1" | /usr/bin/awk -F '.' '
        NR != 1 || $0 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {exit 1}
        {for (i=1; i<=4; i++) if ($i>255 || (length($i)>1 && substr($i,1,1)=="0")) exit 1}
        END {if (NR != 1) exit 1}'
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

# All fields come from the immutable in-memory configuration snapshot.
read_value() {
    printf '%s' "$config_xml" | "$plutil" -extract "$1" raw -expect "$2" -o - - 2>/dev/null ||
        fail "Missing or invalid field: $1 ($config)."
}
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Enable Run as Administrator for this shell action.'
case "$#" in 1|2) :;; *) fail 'Missing or invalid apply arguments.';; esac
ssid=${2-}
single_line "$ssid" || fail 'Wi-Fi name contains unsupported control characters.'
# This record is data from the prepare action, never executable shell code.
load_context() {
    read_line record_kind
    [ "$record_kind" = WIFI_CONTEXT_V2 ] || fail 'Invalid shortcut configuration context.'
    read_line config_dir
    read_line run_id
    read_line service
    read_line device
    config_xml=$(/bin/cat)
}
load_context <<WIFI_CONTEXT_DATA
$1
WIFI_CONTEXT_DATA
config="$config_dir/config.json"
lock="$config_dir/apply.lock"
current_run="$config_dir/current-run"
# Registration is independent. The first probe has drained any earlier write
# before native SSID capture. Lock contention never consumes a state attempt.
guard_run
exec 9>"$lock"
/usr/bin/lockf -s 9 || fail 'Cannot acquire the local network settings lock.'
# A newer task may have registered while this process waited for the lock.
guard_run
observed_state=$(link_state)
case "$observed_state" in
    active) [ -n "$ssid" ] || retry; event=join;;
    inactive) [ -z "$ssid" ] || retry; event=disconnect;;
esac
if [ "$event" = join ]; then
    profile=default.join
    count=$(read_value networks array)
    index=0
    found=0
    while [ "$index" -lt "$count" ]; do
        candidate=$(read_value "networks.$index.ssid" string)
        [ -n "$candidate" ] && single_line "$candidate" || fail 'Invalid configured SSID.'
        if [ "$candidate" = "$ssid" ]; then
            [ "$found" -eq 0 ] || fail 'The current SSID has duplicate profiles.'
            profile="networks.$index.join"
            found=1
        fi
        index=$((index+1))
    done
else
    profile=default.disconnect
fi
mode=$(read_value "$profile.mode" string)
vpn=$(read_value "$profile.shadowrocket" string)
case "$mode" in manual|auto) :;; *) fail 'mode must be manual or auto.';; esac
case "$vpn" in keep|disconnect|connect) :;; *) fail 'shadowrocket must be keep, disconnect or connect.';; esac
if [ "$event" = disconnect ]; then
    [ "$mode:$vpn" = auto:keep ] || fail 'The global disconnect rule must use auto and keep VPN unchanged.'
fi

# Validate only the selected profile. An unused manual profile never blocks auto.
ip= subnet= router= expected_dns= dns_line=
set --
if [ "$mode" = manual ]; then
    ip=$(read_value "$profile.ip" string)
    subnet=$(read_value "$profile.subnetMask" string)
    router=$(read_value "$profile.router" string)
    valid_ipv4 "$ip" || fail 'Invalid IPv4 address.'
    valid_ipv4 "$subnet" || fail 'Invalid subnet mask.'
    valid_ipv4 "$router" || fail 'Invalid router address.'
    /usr/bin/awk -v ip="$ip" -v mask="$subnet" -v router="$router" 'BEGIN {
        split(mask,m,"."); zeros=0; masknum=0
        for (i=1;i<=4;i++) {
            n=m[i]; masknum=masknum*256+n
            for (bit=128;bit>=1;bit/=2) {
                if (n>=bit) {if (zeros) exit 1; n-=bit} else zeros=1
            }
        }
        if (!masknum) exit 1
        split(ip,a,"."); split(router,r,"."); anum=0; rnum=0
        for (i=1;i<=4;i++) {anum=anum*256+a[i]; rnum=rnum*256+r[i]}
        block=4294967296-masknum
        if (a[1]==0 || a[1]==127 || a[1]>=224 || r[1]==0 || r[1]==127 || r[1]>=224) exit 1
        if (block<4 || int(anum/block)!=int(rnum/block) || anum==rnum) exit 1
        if (anum%block==0 || anum%block==block-1 || rnum%block==0 || rnum%block==block-1) exit 1
    }' || fail 'Invalid subnet, host address, or router for this local network.'
    dns_count=$(read_value "$profile.dns" array)
    [ "$dns_count" -gt 0 ] || fail 'A manual profile needs at least one DNS server.'
    index=0
    while [ "$index" -lt "$dns_count" ]; do
        server=$(read_value "$profile.dns.$index" string)
        valid_ipv4 "$server" || fail 'Invalid IPv4 DNS server.'
        set -- "$@" "$server"
        index=$((index+1))
    done
    expected_dns=$(printf '%s\n' "$@")
    dns_line=$(printf '%s\n' "$@" | /usr/bin/paste -sd , -)
fi
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

# Baseline reads decide which settings need changes; final readback is separate.
info=$("$networksetup" -getinfo "$service")
dns=$("$networksetup" -getdnsservers "$service")
# Compare independent service settings, so a DNS-only change never resets IPv4
# and an already-automatic IPv6 configuration never gets rewritten.
if ! matches_ipv4 "$info"; then
    guard_state
    if [ "$mode" = auto ]; then
        "$networksetup" -setdhcp "$service" >/dev/null
    else
        "$networksetup" -setmanual "$service" "$ip" "$subnet" "$router" >/dev/null
    fi
fi
if ! matches_dns "$dns"; then
    guard_state
    if [ "$mode" = auto ]; then
        "$networksetup" -setdnsservers "$service" empty >/dev/null
    else
        "$networksetup" -setdnsservers "$service" "$@" >/dev/null
    fi
fi
if ! matches_ipv6 "$info"; then
    guard_state
    "$networksetup" -setv6automatic "$service" >/dev/null
fi
guard_state

# Pass the validated target to the final verifier. Do not reread settings here.
printf '%s\n' WIFI_TARGET_V2 "$config_dir" "$run_id" "$service" "$device" "$event" "$ssid" \
    "$profile" "$mode" "$vpn" "$ip" "$subnet" "$router" "$dns_line" WIFI_TARGET_END_V2
