#!/usr/bin/env bash
# voice-wrapper.sh — guarantees exit 0 regardless of voice.sh outcome.
/Users/cyril.antoni/Code/tmux-agent-voice/scripts/voice.sh "$@" || true
