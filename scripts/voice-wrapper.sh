#!/usr/bin/env bash
# voice-wrapper.sh — guarantees exit 0 regardless of voice.sh outcome.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$DIR/voice.sh" "$@" || true
