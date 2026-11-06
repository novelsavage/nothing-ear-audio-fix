#!/usr/bin/env bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export XDG_CONFIG_HOME="$fixture/config" XDG_STATE_HOME="$fixture/state" XDG_DATA_HOME="$fixture/data"
export NOTHING_EAR_ADDRESS=AA:BB:CC:DD:EE:FF
export AUDIO_FIX_TEST_LOG="$fixture/calls"
mkdir -p "$fixture/bin"
cat > "$fixture/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AUDIO_FIX_TEST_LOG"
if [[ "$*" == *'restart wireplumber.service'* && -f "${AUDIO_FIX_TEST_LOG}.next-sink" ]]; then
  mv "${AUDIO_FIX_TEST_LOG}.next-sink" "${AUDIO_FIX_TEST_LOG}.sink"
fi
MOCK
cat > "$fixture/bin/pactl" <<'MOCK'
#!/usr/bin/env bash
name='bluez_output.AA:BB:CC:DD:EE:FF'
[[ ! -f "${AUDIO_FIX_TEST_LOG}.sink" ]] || name="$(cat "${AUDIO_FIX_TEST_LOG}.sink")"
case "$*" in
 'list short sinks')
   [[ ! -f "${AUDIO_FIX_TEST_LOG}.query-error" ]] || exit 1
   [[ ! -f "${AUDIO_FIX_TEST_LOG}.disconnected" ]] || exit 0
   printf '1\tbluez_output.11_22_33_44_55_66.1\tPipeWire\n'
   printf '2\t%s\tPipeWire\n' "$name" ;;
 get-default-sink)
   if [[ -f "${AUDIO_FIX_TEST_LOG}.default" ]]; then cat "${AUDIO_FIX_TEST_LOG}.default"; else echo "$name"; fi ;;
 get-sink-volume*) echo 'Volume: 40%' ;;
 '-f json list sinks')
   python3 - "$name" "$AUDIO_FIX_TEST_LOG" <<'PY'
import json,sys
from pathlib import Path
name,log=sys.argv[1:]
names=[name]
default=Path(log+'.default')
if default.exists():names.append(default.read_text().strip())
print(json.dumps([{'name':n,'volume':{'mono':{'value':26214}},'mute':True} for n in names]))
PY
   ;;
 set-sink-volume*|set-sink-mute*) printf '%s\n' "$*" >> "${AUDIO_FIX_TEST_LOG}.volume" ;;
 set-default-sink*)
   default=''; [[ ! -f "${AUDIO_FIX_TEST_LOG}.default" ]] || default="$(cat "${AUDIO_FIX_TEST_LOG}.default")"
   [[ "$2" == "$name" || "$2" == "$default" ]] || { echo 'Stale sink name used' >&2; exit 1; }
   printf '%s\n' "$2" >> "${AUDIO_FIX_TEST_LOG}.selected" ;;
 *) echo "Unexpected pactl operation: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$fixture/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
script="$project/nothing-ear-audio-fix"
state="$XDG_STATE_HOME/nothing-ear-audio-fix"
# Invalid input must not create files or call services.
if NOTHING_EAR_ADDRESS=invalid "$script" apply > /dev/null 2>&1; then exit 1; fi
[[ ! -e "$XDG_CONFIG_HOME" && ! -e "$XDG_STATE_HOME" ]]
mkdir -p "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d" "$XDG_CONFIG_HOME/systemd/user/plasma-kded6.service.d"
printf '# original\n' > "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/10-local-audio.conf"
printf '# original kded\n' > "$XDG_CONFIG_HOME/systemd/user/plasma-kded6.service.d/10-local-audio.conf"
"$script" apply > /dev/null
grep -Fq 'bluez_card.AA_BB_CC_DD_EE_FF' "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/51-nothing-ear-volume.conf"
grep -Fq 'restart wireplumber.service' "$AUDIO_FIX_TEST_LOG"
grep -Fq 'restart plasma-plasmashell.service plasma-kded6.service' "$AUDIO_FIX_TEST_LOG"
grep -Fq -- '--address AA:BB:CC:DD:EE:FF' "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/20-nothing-ear-volume-compat.conf"
: > "$AUDIO_FIX_TEST_LOG"
unset NOTHING_EAR_ADDRESS
"$script" apply > /dev/null
if grep -q restart "$AUDIO_FIX_TEST_LOG"; then echo 'Idempotency failed'; exit 1; fi
if NOTHING_EAR_ADDRESS=11:22:33:44:55:66 "$script" apply >/dev/null 2>&1; then exit 1; fi
"$script" undo > /dev/null
[[ "$(cat "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/10-local-audio.conf")" == '# original' ]]
[[ "$(cat "$XDG_CONFIG_HOME/systemd/user/plasma-kded6.service.d/10-local-audio.conf")" == '# original kded' ]]
[[ ! -e "$XDG_CONFIG_HOME/systemd/user/plasma-plasmashell.service.d/10-local-audio.conf" ]]
[[ ! -e "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/20-nothing-ear-volume-compat.conf" ]]
[[ ! -e "$XDG_DATA_HOME/wireplumber/scripts/monitors/bluez.lua" ]]
[[ ! -e "$state/installed" ]]
echo 'PASS: input validation, generated config, kded restart, idempotency, persisted address, device change rejection, undo'

"$script" apply > /dev/null
rm -f "${AUDIO_FIX_TEST_LOG}.selected"
"$script" auto-connect > /dev/null
[[ "$(wc -l < "${AUDIO_FIX_TEST_LOG}.selected")" == 1 ]]
"$script" auto-connect > /dev/null
[[ "$(wc -l < "${AUDIO_FIX_TEST_LOG}.selected")" == 1 ]]
touch "${AUDIO_FIX_TEST_LOG}.query-error"
if "$script" auto-connect >/dev/null 2>&1; then exit 1; fi
[[ -f "$state/connected" ]]
rm "${AUDIO_FIX_TEST_LOG}.query-error"
touch "${AUDIO_FIX_TEST_LOG}.disconnected"
"$script" auto-connect > /dev/null
[[ ! -f "$state/connected" ]]
rm "${AUDIO_FIX_TEST_LOG}.disconnected"
printf '%s\n' 'bluez_output.AA_BB_CC_DD_EE_FF.1' > "${AUDIO_FIX_TEST_LOG}.sink"
"$script" auto-connect > /dev/null
[[ "$(tail -n1 "${AUDIO_FIX_TEST_LOG}.selected")" == 'bluez_output.AA_BB_CC_DD_EE_FF.1' ]]
[[ "$(wc -l < "${AUDIO_FIX_TEST_LOG}.selected")" == 2 ]]
# Configuration repair may rename the sink; selection must query again.
rm "$state/connected"
printf '# force repair\n' > "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/51-nothing-ear-volume.conf"
printf '%s\n' 'bluez_output.AA:BB:CC:DD:EE:FF.0' > "${AUDIO_FIX_TEST_LOG}.next-sink"
"$script" auto-connect > /dev/null
[[ "$(tail -n1 "${AUDIO_FIX_TEST_LOG}.selected")" == 'bluez_output.AA:BB:CC:DD:EE:FF.0' ]]
"$script" enable-auto > /dev/null
grep -Fq 'OnUnitInactiveSec=5s' "$XDG_CONFIG_HOME/systemd/user/nothing-ear-audio-fix.timer"
"$script" disable-auto > /dev/null
"$script" undo > /dev/null
echo 'PASS: connection detection, both sink name formats, stale-name repair, query failure, timer lifecycle'

# A disconnected headset must not make a restart switch away from a wired output.
printf '%s\n' 'alsa_output.wired' > "${AUDIO_FIX_TEST_LOG}.default"
touch "${AUDIO_FIX_TEST_LOG}.disconnected"
"$script" restart >/dev/null
[[ "$(tail -n1 "${AUDIO_FIX_TEST_LOG}.selected")" == 'alsa_output.wired' ]]
grep -Fxq 'set-sink-volume alsa_output.wired 26214' "${AUDIO_FIX_TEST_LOG}.volume"
grep -Fxq 'set-sink-mute alsa_output.wired 1' "${AUDIO_FIX_TEST_LOG}.volume"
rm "${AUDIO_FIX_TEST_LOG}.default" "${AUDIO_FIX_TEST_LOG}.disconnected"
echo 'PASS: restart preserves the selected wired output, volume and mute'

# Upgrade from the original three-file backup schema, retaining newer pre-existing files.
mkdir -p "$state/backup/systemd/user/wireplumber.service.d"
printf '# pre-install original\n' > "$state/backup/systemd/user/wireplumber.service.d/10-local-audio.conf"
printf '# old applied setting\n' > "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/10-local-audio.conf"
printf '# newer pre-existing kded setting\n' > "$XDG_CONFIG_HOME/systemd/user/plasma-kded6.service.d/10-local-audio.conf"
printf '# previous compatibility unit\n' > "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/20-nothing-ear-volume-compat.conf"
touch "$state/installed"
"$script" apply > /dev/null
"$script" undo > /dev/null
[[ "$(cat "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/10-local-audio.conf")" == '# pre-install original' ]]
[[ "$(cat "$XDG_CONFIG_HOME/systemd/user/plasma-kded6.service.d/10-local-audio.conf")" == '# newer pre-existing kded setting' ]]
[[ "$(cat "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/20-nothing-ear-volume-compat.conf")" == '# previous compatibility unit' ]]
echo 'PASS: old-version backup migration preserves both original and newly managed files'

# Refuse a foreign WirePlumber override before touching configuration or installed state.
mkdir -p "$XDG_DATA_HOME/wireplumber/scripts/monitors"
printf '%s\n' '-- user override' > "$XDG_DATA_HOME/wireplumber/scripts/monitors/bluez.lua"
if "$script" apply >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$state/installed" ]]
[[ "$(cat "$XDG_DATA_HOME/wireplumber/scripts/monitors/bluez.lua")" == '-- user override' ]]
echo 'PASS: unrelated user script preserved'
# Stopping the timer must remain possible without an address file.
rm "$state/device-address"
"$script" disable-auto >/dev/null
echo 'PASS: disable-auto works without a saved device address'
