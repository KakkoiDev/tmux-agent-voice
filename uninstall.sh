#!/usr/bin/env bash
# uninstall.sh - silence it, unwire it, remove the symlink.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/toolkit-ui.sh
source "$HERE/lib/toolkit-ui.sh"
tk_init agent-voice "${VOICE_DIR:-$HOME/.tmux-agent-voice}"

# Kill any speaker first. Unwiring a talking plugin leaves it talking.
"$HERE/scripts/voice.sh" stop >/dev/null 2>&1 || true

# Only unset the tracker hook if it is still ours. Someone may have chained it.
CUR="$(tk_opt @agent-tracker-on-transition)"
if [[ "$CUR" == "$HERE/scripts/voice.sh hook-transition" ]]; then
    tk_tmux set -gu @agent-tracker-on-transition 2>/dev/null || true
    printf 'unwired @agent-tracker-on-transition\n'
elif [[ "$CUR" == *voice.sh* ]]; then
    printf 'LEFT    @agent-tracker-on-transition, it is chained with something else:\n' >&2
    printf '          %s\n' "$CUR" >&2
    printf '        Edit it by hand.\n' >&2
else
    printf 'skipped @agent-tracker-on-transition, not ours\n'
fi

# tracker reads a cache with no age check, so unsetting the option is not enough.
TRACKER_DIR="${TRACKER_DIR:-$HOME/.tmux-agent-tracker}"
rm -f "$TRACKER_DIR/config_cache" 2>/dev/null || true

for o in voice rate enabled scope sentences notify key key-stop key-skip; do
    tk_tmux set -gu "@agent-voice-$o" 2>/dev/null || true
done
tk_config_invalidate

rm -f "$HOME/.local/bin/tmux-agent-voice"
printf 'removed ~/.local/bin/tmux-agent-voice\n'
printf 'state left at %s; rm -rf it to finish.\n' "$TK_DIR"
printf 'remove the run-shell line from ~/.tmux.conf too, then reload.\n'
