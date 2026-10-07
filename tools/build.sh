#!/bin/sh
# Build source into an unsigned shortcut; --sign additionally uses Apple's signer.
set -eu
umask 077
case "${1-}" in
    ''|--sign) :;;
    --help) printf '%s\n' 'Usage: sh tools/build.sh [--sign]'; exit 0;;
    *) printf '%s\n' 'Usage: sh tools/build.sh [--sign]' >&2; exit 1;;
esac
[ "$#" -le 1 ] || exit 1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/dist"
temporary=$(/usr/bin/mktemp "$root/dist/.workflow.XXXXXX")
trap 'rm -f "$temporary"' 0
trap 'exit 1' 1 2 15
cp "$root/shortcut/workflow.json" "$temporary"
while read -r index source; do
    script=$(cat "$root/$source")
    /usr/bin/plutil -replace "WFWorkflowActions.$index.WFWorkflowActionParameters.Script" \
        -string "$script" "$temporary"
done < "$root/shortcut/scripts.txt"
unsigned="$root/dist/WiFi-Switch.unsigned.shortcut"
/usr/bin/plutil -convert binary1 -o "$unsigned" "$temporary"
printf 'Built: %s\n' "$unsigned"
if [ "${1-}" = --sign ]; then
    signed="$root/dist/WiFi-Switch.shortcut"
    /usr/bin/shortcuts sign --mode anyone --input "$unsigned" --output "$signed"
    printf 'Import in Shortcuts: %s\n' "$signed"
fi
