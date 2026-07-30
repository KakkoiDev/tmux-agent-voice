#!/usr/bin/env bash
# install.sh - symlink the CLI, wire the tracker hook, prove it works.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/toolkit-ui.sh
source "$HERE/lib/toolkit-ui.sh"
tk_init agent-voice "${VOICE_DIR:-$HOME/.tmux-agent-voice}"
tk_require_version 0.2.0

mkdir -p "$TK_DIR" "$HOME/.local/bin"
ln -sf "$HERE/bin/tmux-agent-voice" "$HOME/.local/bin/tmux-agent-voice"
printf 'linked  ~/.local/bin/tmux-agent-voice\n'

# ── tracker wiring ────────────────────────────────────────────────────
#
# @agent-tracker-on-transition, never on-completed or on-blocked: both of those
# are already occupied by ntfy.sh pushes on this machine, and tracker fires
# HOOK_ON_TRANSITION in addition to HOOK_ON_<TO>, so this adds a channel instead
# of taking one. Refuses to overwrite anything that is not already ours.
WANT="$HERE/scripts/voice.sh hook-transition"
CUR="$(tk_opt @agent-tracker-on-transition)"
if [[ -z "$CUR" ]]; then
    tk_opt_set @agent-tracker-on-transition "$WANT"
    printf 'wired   @agent-tracker-on-transition\n'
elif [[ "$CUR" == *voice.sh* ]]; then
    tk_opt_set @agent-tracker-on-transition "$WANT"
    printf 'rewired @agent-tracker-on-transition (was ours)\n'
else
    printf 'REFUSED @agent-tracker-on-transition is already set to something else:\n' >&2
    printf '          %s\n' "$CUR" >&2
    printf '        Chain it yourself, putting voice.sh last so it receives the\n' >&2
    printf '        positional arguments, then re-run this script:\n' >&2
    printf '          tmux set -g @agent-tracker-on-transition '\''%s; %s'\''\n' "$CUR" "$WANT" >&2
    exit 1
fi

# tracker's _load_config_fast (tracker.sh:697) sources its config cache with no
# age check at all, so a cache written before the option was set keeps
# HOOK_ON_TRANSITION='' indefinitely and the hook silently never fires. Deleting
# it forces one real load_config.
TRACKER_DIR="${TRACKER_DIR:-$HOME/.tmux-agent-tracker}"
if [[ -f "$TRACKER_DIR/config_cache" ]]; then
    rm -f "$TRACKER_DIR/config_cache"
    printf 'cleared tracker config cache (stale-forever fast path)\n'
fi
tk_config_invalidate

printf '\n'
exec "$HERE/scripts/voice.sh" doctor
