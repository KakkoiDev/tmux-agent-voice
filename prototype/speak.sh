#!/usr/bin/env bash
# speak.sh - spoken turn-end summaries with mid-sentence interrupt.
#
# Prototype. Deliberately has no tmux-toolkit dependency: the pieces it would
# want from the library (menu, lock) are not built yet, so this proves the
# mechanism first and gets ported when toolkit-ui.sh lands.
#
#   speak.sh hook            Stop-hook payload on stdin
#   speak.sh speak <file>    speak a queue file, one sentence per line
#   speak.sh stop            silence, immediately, mid-word
#   speak.sh skip            abandon this sentence, continue with the next
#   speak.sh status          what is speaking and where it got to
#   speak.sh demo            four canned sentences, for trying stop and skip
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${TA_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/talking-agents}"
SPEAKER_PID="$STATE/speaker.pid"
CHILD_PID="$STATE/child.pid"
QUEUE="$STATE/queue.txt"
CURSOR="$STATE/cursor"
LOG="$STATE/log"

mkdir -p "$STATE"

_opt() { tmux show-option -gqv "$1" 2>/dev/null || true; }
_log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }

VOICE=""; RATE=""; ENABLED=""; SCOPE=""; MAXS=""
_config() {
    VOICE="$(_opt @voice-voice)";     VOICE="${VOICE:-${TA_VOICE:-Daniel}}"
    RATE="$(_opt @voice-rate)";       RATE="${RATE:-${TA_RATE:-200}}"
    ENABLED="$(_opt @voice-enabled)"; ENABLED="${ENABLED:-${TA_ENABLED:-on}}"
    SCOPE="$(_opt @voice-scope)";     SCOPE="${SCOPE:-${TA_SCOPE:-active}}"
    MAXS="$(_opt @voice-sentences)";  MAXS="${MAXS:-${TA_SENTENCES:-4}}"
}

# ── stop / skip ───────────────────────────────────────────────────────
#
# Two different kills on purpose. TERM to the loop runs its trap, which takes
# the current `say` down with it. TERM to `say` alone lets the loop's `wait`
# return and move on, which is what skip-ahead is.

_pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

cmd_stop() {
    local loop child
    loop="$(cat "$SPEAKER_PID" 2>/dev/null || true)"
    child="$(cat "$CHILD_PID" 2>/dev/null || true)"
    _pid_alive "$loop"  && kill -TERM "$loop"  2>/dev/null || true
    # Belt and braces: if the loop already died, the child can outlive it.
    _pid_alive "$child" && kill -TERM "$child" 2>/dev/null || true
    rm -f "$SPEAKER_PID" "$CHILD_PID" 2>/dev/null || true
    _log "stop"
}

cmd_skip() {
    local child
    child="$(cat "$CHILD_PID" 2>/dev/null || true)"
    if _pid_alive "$child"; then
        kill -TERM "$child" 2>/dev/null || true
        _log "skip at sentence $(cat "$CURSOR" 2>/dev/null || echo '?')"
    fi
}

# ── the queue ─────────────────────────────────────────────────────────

_child=""
_on_term() {
    [[ -n "$_child" ]] && kill -TERM "$_child" 2>/dev/null || true
    rm -f "$SPEAKER_PID" "$CHILD_PID" 2>/dev/null || true
    exit 0
}

cmd_speak() {
    local qfile="${1:?usage: speak.sh speak <file>}"
    [[ -r "$qfile" ]] || { echo "speak.sh: cannot read $qfile" >&2; exit 1; }
    _config
    command -v say >/dev/null 2>&1 || { echo "speak.sh: no say(1)" >&2; exit 1; }

    trap _on_term TERM INT
    printf '%s' "$$" > "$SPEAKER_PID"
    local n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "${line//[[:space:]]/}" ]] || continue
        n=$((n + 1))
        printf '%s' "$n" > "$CURSOR"
        # Through stdin, not argv: a sentence starting with a dash would
        # otherwise be parsed as a say(1) flag. $! is the last pid of the
        # pipeline, which is say itself.
        printf '%s\n' "$line" | say -v "$VOICE" -r "$RATE" -f - &
        _child=$!
        printf '%s' "$_child" > "$CHILD_PID"
        wait "$_child" 2>/dev/null || true   # non-zero means skip killed it
        _child=""
    done < "$qfile"
    rm -f "$SPEAKER_PID" "$CHILD_PID" 2>/dev/null || true
    _log "done $n sentence(s)"
}

# ── hook ──────────────────────────────────────────────────────────────

cmd_hook() {
    # Recursion guard. Kept even though the summariser was cut, because any
    # future LLM in this path is another Claude Code that fires this same hook.
    [[ -n "${CLAUDE_VOICE_SPEAKING:-}" ]] && exit 0

    local payload; payload="$(cat)"
    _config
    case "$ENABLED" in off|0|false|no) _log "skip: disabled"; exit 0 ;; esac

    if [[ "$SCOPE" == "active" ]]; then
        local active; active="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
        if [[ -z "${TMUX_PANE:-}" || "$active" != "${TMUX_PANE:-}" ]]; then
            _log "skip: pane ${TMUX_PANE:-none} not active ($active)"
            exit 0
        fi
    fi

    local transcript
    if command -v jq >/dev/null 2>&1; then
        transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
    else
        transcript=""
    fi
    [[ -n "$transcript" && -r "$transcript" ]] || { _log "skip: no transcript"; exit 0; }

    "$HERE/extract.sh" "$transcript" "$MAXS" > "$QUEUE.tmp" 2>>"$LOG" || true
    if [[ ! -s "$QUEUE.tmp" ]]; then _log "skip: nothing speakable"; rm -f "$QUEUE.tmp"; exit 0; fi
    mv "$QUEUE.tmp" "$QUEUE"

    cmd_stop                                   # barge-in: newest turn wins
    # Detached, because a hook that waits holds the turn open for the whole
    # length of the audio.
    nohup "$HERE/speak.sh" speak "$QUEUE" >>"$LOG" 2>&1 &
    disown 2>/dev/null || true
    exit 0
}

cmd_status() {
    local loop child
    loop="$(cat "$SPEAKER_PID" 2>/dev/null || true)"
    child="$(cat "$CHILD_PID" 2>/dev/null || true)"
    _config
    printf 'voice   %s at %s wpm, scope %s, enabled %s\n' "$VOICE" "$RATE" "$SCOPE" "$ENABLED"
    printf 'speaker %s\n' "$(_pid_alive "$loop"  && echo "$loop running"  || echo idle)"
    printf 'say     %s\n' "$(_pid_alive "$child" && echo "$child running" || echo idle)"
    # grep -c prints 0 and exits 1 on no match; `|| echo 0` would emit two lines.
    local total; total="$(grep -c . "$QUEUE" 2>/dev/null)" || total=0
    printf 'cursor  sentence %s of %s\n' \
        "$(cat "$CURSOR" 2>/dev/null || echo 0)" "${total:-0}"
    printf 'state   %s\n' "$STATE"
}

cmd_demo() {
    cat > "$QUEUE" <<'EOF'
One. The queue is four sentences long and this is the first of them.
Two. Hit skip now and you should land in the middle of sentence three.
Three. This sentence is deliberately long so there is room to interrupt it, and if you are hearing the whole thing then skip did not fire.
Four. Last one, so stop here proves that silence arrives mid word.
EOF
    cmd_stop
    nohup "$HERE/speak.sh" speak "$QUEUE" >>"$LOG" 2>&1 &
    disown 2>/dev/null || true
    echo "speaking 4 sentences; try: ./speak.sh skip   and   ./speak.sh stop"
}

case "${1:-}" in
    hook)   cmd_hook ;;
    speak)  cmd_speak "${2:-}" ;;
    stop)   cmd_stop ;;
    skip)   cmd_skip ;;
    status) cmd_status ;;
    demo)   cmd_demo ;;
    *)      echo "usage: speak.sh {hook|speak <file>|stop|skip|status|demo}" >&2; exit 1 ;;
esac
