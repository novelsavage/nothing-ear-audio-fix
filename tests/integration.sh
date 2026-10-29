#!/usr/bin/env bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export XDG_CONFIG_HOME="$fixture/config" XDG_STATE_HOME="$fixture/state"
export NOTHING_EAR_ADDRESS=AA:BB:CC:DD:EE:FF
export AUDIO_FIX_TEST_LOG="$fixture/calls"
mkdir -p "$fixture/bin"
cat > "$fixture/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AUDIO_FIX_TEST_LOG"
MOCK
cat > "$fixture/bin/pactl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
 'list short sinks') [[ ! -f "${AUDIO_FIX_TEST_LOG}.disconnected" ]] || exit 0; printf '1\tbluez_output.AA:BB:CC:DD:EE:FF\tPipeWire\n' ;;
 get-default-sink) echo 'bluez_output.AA:BB:CC:DD:EE:FF' ;;
 get-sink-volume*) echo 'Volume: 40%' ;;
 set-default-sink*) echo selected >> "${AUDIO_FIX_TEST_LOG}.selected" ;;
 *) echo "Unexpected pactl operation: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
script="$project/nothing-ear-audio-fix"
# Invalid input must not create files or call services.
if NOTHING_EAR_ADDRESS=invalid "$script" apply > /dev/null 2>&1; then exit 1; fi
[[ ! -e "$XDG_CONFIG_HOME" ]]
mkdir -p "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d"
printf '# original\n' > "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/10-local-audio.conf"
"$script" apply > /dev/null
grep -Fq 'bluez_card.AA_BB_CC_DD_EE_FF' "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/51-nothing-ear-volume.conf"
grep -Fq 'Environment=PIPEWIRE_REMOTE=pipewire-0' "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/10-local-audio.conf"
grep -Fq 'restart wireplumber.service' "$AUDIO_FIX_TEST_LOG"
: > "$AUDIO_FIX_TEST_LOG"
unset NOTHING_EAR_ADDRESS
"$script" apply > /dev/null
if grep -q restart "$AUDIO_FIX_TEST_LOG"; then echo 'Idempotency failed'; exit 1; fi
"$script" undo > /dev/null
[[ "$(cat "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/10-local-audio.conf")" == '# original' ]]
[[ ! -e "$XDG_CONFIG_HOME/systemd/user/plasma-plasmashell.service.d/10-local-audio.conf" ]]
[[ ! -e "$XDG_STATE_HOME/nothing-ear-audio-fix/installed" ]]
"$script" apply > /dev/null
"$script" undo > /dev/null
[[ "$(cat "$XDG_CONFIG_HOME/systemd/user/wireplumber.service.d/10-local-audio.conf")" == '# original' ]]
echo 'PASS: input validation, generated config, restart, idempotency, persisted address, undo, reapply'

"$script" apply > /dev/null
rm -f "${AUDIO_FIX_TEST_LOG}.selected"
"$script" auto-connect > /dev/null
[[ "$(wc -l < "${AUDIO_FIX_TEST_LOG}.selected")" == 1 ]]
"$script" auto-connect > /dev/null
[[ "$(wc -l < "${AUDIO_FIX_TEST_LOG}.selected")" == 1 ]]
touch "${AUDIO_FIX_TEST_LOG}.disconnected"
"$script" auto-connect > /dev/null
[[ ! -f "$XDG_STATE_HOME/nothing-ear-audio-fix/connected" ]]
rm "${AUDIO_FIX_TEST_LOG}.disconnected"
"$script" auto-connect > /dev/null
[[ "$(wc -l < "${AUDIO_FIX_TEST_LOG}.selected")" == 2 ]]
"$script" enable-auto > /dev/null
grep -Fq 'OnUnitInactiveSec=5s' "$XDG_CONFIG_HOME/systemd/user/nothing-ear-audio-fix.timer"
"$script" disable-auto > /dev/null
echo 'PASS: one execution per connection, disconnect/reconnect, timer enable/disable'
