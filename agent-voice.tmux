#!/usr/bin/env bash
# agent-voice.tmux - TPM entry point.
#
# Binds three keys and nothing else. The tracker wiring is install.sh's job,
# because it has to not clobber an option someone else already owns and that is
# a decision, not a default.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/scripts" && pwd)"

# shellcheck source=lib/toolkit-ui.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/toolkit-ui.sh"
tk_init agent-voice "${VOICE_DIR:-$HOME/.tmux-agent-voice}"

KEY_MENU="$(tk_opt @agent-voice-key V)"
KEY_STOP="$(tk_opt @agent-voice-key-stop BSpace)"
KEY_SKIP="$(tk_opt @agent-voice-key-skip Tab)"

# Single-quoted paths: a plugin directory containing a space otherwise splits
# inside the shell command that run-shell hands to /bin/sh.
tk_tmux bind-key    "$KEY_MENU" run-shell "'$SCRIPTS_DIR/voice-wrapper.sh' menu"
tk_tmux bind-key    "$KEY_STOP" run-shell "'$SCRIPTS_DIR/voice.sh' stop"
# -r so a run of skips does not need the prefix re-pressed for each one.
tk_tmux bind-key -r "$KEY_SKIP" run-shell "'$SCRIPTS_DIR/voice.sh' skip"
