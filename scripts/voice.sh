#!/usr/bin/env bash
# voice.sh - spoken turn-endings for tmux agents.
#
# Wiring is through tmux-agent-tracker's existing transition hooks, not through
# new ~/.claude/settings.json entries:
#
#   @agent-tracker-on-transition  ->  voice.sh hook-transition
#
# Tracker passes `from to sid project summary` and already owns the pane and
# project mapping, so nothing here has to parse a harness payload.
#
# `on-transition` and not `on-completed`/`on-blocked` specifically because those
# two are already occupied on this machine by ntfy.sh pushes. tracker fires
# HOOK_ON_<TO> *and* HOOK_ON_TRANSITION for every change, so this is a second
# channel rather than a replacement, and installing costs the user nothing they
# already rely on.
#
# Entry point: toolkit-ui.sh, including on the hook path. The library's rule is
# that a hook must not pay for the UI modules because a Claude hook fires ~12
# times per turn, but a tracker *transition* hook fires once per turn, and the
# speaker mutex lives in lock.sh. One entry point, paid once.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_DIR="${VOICE_DIR:-$HOME/.tmux-agent-voice}"

# shellcheck source=../lib/toolkit-ui.sh
source "$SCRIPTS_DIR/../lib/toolkit-ui.sh"
tk_init agent-voice "$VOICE_DIR"
tk_require_version 0.2.0

mkdir -p "$TK_DIR" 2>/dev/null || true

CHILD_PID="$TK_DIR/child.pid"
QUEUE="$TK_DIR/queue.txt"
CURSOR="$TK_DIR/cursor"
LOCK=speaker

TRACKER_DB="${TRACKER_DB:-$HOME/.tmux-agent-tracker/tracker.db}"
# Pi's session dirs; overridable the same way TRACKER_DB is, for tests.
PI_SESSIONS_ROOT="${PI_SESSIONS_ROOT:-$HOME/.pi/agent/sessions}"

VOICE=""; RATE=""; ENABLED=""; SCOPE=""; SENTENCES=""; NOTIFY=""
_config() {
    tk_config_load agent-voice 5 \
        VOICE:@agent-voice-voice:Daniel \
        RATE:@agent-voice-rate:200 \
        ENABLED:@agent-voice-enabled:on \
        SCOPE:@agent-voice-scope:active \
        SENTENCES:@agent-voice-sentences:4 \
        NOTIFY:@agent-voice-notify:on
}

_is_on() { case "${1:-}" in on|1|true|yes) return 0 ;; *) return 1 ;; esac; }

# ── guards ────────────────────────────────────────────────────────────

# The summariser this once shelled out to was another Claude Code, which fires
# the same tracker transition. That summariser is gone (17s, see README) but the
# guard costs one line and any future one reintroduces the loop.
_guard_recursion() { [[ -z "${CLAUDE_VOICE_SPEAKING:-}" ]]; }

# tk_tmux, not raw tmux, so TK_TMUX_DISABLED makes this a no-op under test.
_active_pane() { tk_tmux display-message -p '#{pane_id}' 2>/dev/null || true; }

# _pane_of <session_id> - tracker already stores it, so this never guesses.
_pane_of() {
    [[ -r "$TRACKER_DB" ]] || return 0
    tk_sql "$TRACKER_DB" \
        "SELECT COALESCE(tmux_pane,'') FROM sessions WHERE session_id='$(tk_sql_esc "$1")';" \
        2>/dev/null || true
}

# _harness_of <session_id> - pi or claude, for choosing the extractor.
#
# tracker.db's sessions.agent_client records the harness ('pi', 'claude', ...)
# but pi detection upstream keys on a '/.pi/sessions/' pattern that does not
# match the real ~/.pi/agent/sessions layout, so a pi session can sit in the db
# as 'claude' and still must route to the pi extractor. The session_id shape is
# checked as a backstop: tracker stores pi session ids as the full transcript
# path, claude ids are UUIDs. Unknown harnesses fall through to claude, which
# is the pre-pi behaviour.
_harness_of() {
    local sid="$1" h=""
    [[ -r "$TRACKER_DB" ]] || { printf 'claude'; return 0; }
    h="$(tk_sql "$TRACKER_DB" \
        "SELECT COALESCE(agent_client,'claude') FROM sessions WHERE session_id='$(tk_sql_esc "$sid")';" \
        2>/dev/null || true)"
    case "$h" in
        pi|pi-signed) printf 'pi'; return 0 ;;
    esac
    case "$sid" in
        */.pi/sessions/*|*/.pi/agent/sessions/*) printf 'pi' ;;
        *) printf '%s' "${h:-claude}" ;;
    esac
}

# _pi_session_dir <session_id> - the session directory extract-pi.sh reads.
#
# Tracker stores pi session ids as the full transcript path, so dirname is the
# session directory. When the id is not a path, fall back to the tracker's cwd:
# pi names its session dirs after the working directory
# (--Users-me-.treehouse-project--), so derive the candidate name, then scan
# the root as ground truth - each session file records the cwd it launched in.
_pi_session_dir() {
    local sid="$1" cwd="" d f
    case "$sid" in
        */.pi/sessions/*|*/.pi/agent/sessions/*)
            d="$(dirname "$sid")"
            [[ -d "$d" ]] && { printf '%s' "$d"; return 0; }
            ;;
    esac
    [[ -r "$TRACKER_DB" ]] || return 0
    cwd="$(tk_sql "$TRACKER_DB" \
        "SELECT cwd FROM sessions WHERE session_id='$(tk_sql_esc "$sid")';" 2>/dev/null || true)"
    [[ -n "$cwd" ]] || return 0
    # pi encodes the cwd as --components-joined-by-dashes-- (dots kept); derive
    # the candidate name from the path alone, then scan as ground truth.
    local rel="${cwd#/}"; rel="${rel%/}"
    d="$PI_SESSIONS_ROOT/--${rel//\//-}--"
    if [[ -d "$d" ]] && [[ -n "$(find "$d" -maxdepth 1 -name '*.jsonl' -print -quit 2>/dev/null)" ]]; then
        printf '%s' "$d"; return 0
    fi
    for d in "$PI_SESSIONS_ROOT"/*/; do
        [[ -d "$d" ]] || continue
        f="$(find "$d" -maxdepth 1 -name '*.jsonl' -print 2>/dev/null | LC_ALL=C sort | tail -1)"
        [[ -n "$f" ]] || continue
        if [[ "$(jq -r 'select(.type=="session") | .cwd // empty' "$f" 2>/dev/null | head -1)" == "$cwd" ]]; then
            printf '%s' "$d"; return 0
        fi
    done
    return 0
}

# _transcript_of <session_id>
#
# CLAUDE_CONFIG_DIR relocates the whole tree, so $HOME/.claude is a fallback and
# not an assumption. A glob over projects/ avoids reimplementing the cwd->slug
# rule, which lowercases nothing but replaces both / and . with -.
_transcript_of() {
    local sid="$1" base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" f
    for f in "$base"/projects/*/"$sid".jsonl; do
        [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 0
}

# ── speaking ──────────────────────────────────────────────────────────

_child=""
_on_term() {
    [[ -n "$_child" ]] && kill -TERM "$_child" 2>/dev/null || true
    rm -f "$CHILD_PID" 2>/dev/null || true
    tk_unlock "$LOCK"
    exit 0
}

cmd_speak() {
    local qfile="${1:?usage: voice.sh speak <file>}"
    [[ -r "$qfile" ]] || tk_die "cannot read $qfile"
    _config
    tk_require say

    # The lock's pid file is the speaker pid, which is what stop targets. No
    # separate speaker.pid to go stale.
    tk_lock "$LOCK" || { tk_debug "speak: another speaker holds the lock"; return 0; }
    trap _on_term TERM INT

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

    rm -f "$CHILD_PID" 2>/dev/null || true
    tk_unlock "$LOCK"
    tk_debug "spoke $n sentence(s)"
}

_holder() {
    local d; d="$(tk_lock_dir "$LOCK")"
    [[ -r "$d/pid" ]] || return 0
    # read returns non-zero at EOF with no trailing newline even though it
    # assigned the variable, so its status is not "no pid".
    local p=""; read -r p < "$d/pid" 2>/dev/null || true
    printf '%s' "$p"
}

# Two different kills. TERM to the loop runs its trap, which takes the current
# say down with it. TERM to say alone lets the loop's wait return and move on,
# which is exactly what skip-ahead is.
cmd_stop() {
    local loop child
    loop="$(_holder)"
    child="$(cat "$CHILD_PID" 2>/dev/null || true)"
    [[ -n "$loop"  ]] && kill -TERM "$loop"  2>/dev/null || true
    [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null || true
    rm -f "$CHILD_PID" 2>/dev/null || true
    # Reset here, not in cmd_speak. On a barge-in the next speaker is a process
    # that has not started yet, so anything it does is a second too late: for
    # that whole second `status` would report the killed queue's position.
    printf '0' > "$CURSOR"
    tk_unlock "$LOCK"
    tk_debug "stop"
}

cmd_skip() {
    local child
    child="$(cat "$CHILD_PID" 2>/dev/null || true)"
    if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
        kill -TERM "$child" 2>/dev/null || true
        tk_debug "skip at sentence $(cat "$CURSOR" 2>/dev/null || printf 0)"
    fi
}

# _launch <queue> - barge in, then speak detached.
#
# Detached because a transition hook that waits holds the turn open for the whole
# length of the audio.
_launch() {
    cmd_stop
    nohup "$SCRIPTS_DIR/voice.sh" speak "$1" >>"$(tk_log_file 2>/dev/null || printf /dev/null)" 2>&1 &
    disown 2>/dev/null || true
}

_say_now() {
    printf '%s\n' "$1" > "$QUEUE"
    _launch "$QUEUE"
}

# ── tracker transition hooks ──────────────────────────────────────────

# speak-session <from> <to> <sid> <project> <summary>
cmd_speak_session() {
    local sid="${3:-}" project="${4:-}"
    _guard_recursion || exit 0
    _config
    _is_on "$ENABLED" || { tk_debug "skip: disabled"; exit 0; }
    [[ -n "$sid" ]] || exit 0

    if [[ "$SCOPE" == "active" ]]; then
        local pane active
        pane="$(_pane_of "$sid")"
        active="$(_active_pane)"
        if [[ -z "$pane" || "$pane" != "$active" ]]; then
            tk_debug "skip: $project pane ${pane:-none} not active (${active:-none})"
            exit 0
        fi
    fi

    local harness transcript
    harness="$(_harness_of "$sid")"
    case "$harness" in
        pi)
            local pdir; pdir="$(_pi_session_dir "$sid")"
            [[ -n "$pdir" ]] || { tk_debug "skip: no pi session dir for $sid"; exit 0; }
            "$SCRIPTS_DIR/extract-pi.sh" "$pdir" "$SENTENCES" > "$QUEUE.tmp" 2>/dev/null || true
            ;;
        *)
            transcript="$(_transcript_of "$sid")"
            [[ -n "$transcript" ]] || { tk_debug "skip: no transcript for $sid"; exit 0; }
            "$SCRIPTS_DIR/extract.sh" "$transcript" "$SENTENCES" > "$QUEUE.tmp" 2>/dev/null || true
            ;;
    esac
    if [[ ! -s "$QUEUE.tmp" ]]; then
        rm -f "$QUEUE.tmp"; tk_debug "skip: nothing speakable in $sid"; exit 0
    fi
    mv -f "$QUEUE.tmp" "$QUEUE"
    _launch "$QUEUE"
}

# notify-blocked <from> <to> <sid> <project> <summary>
#
# Inverted scope on purpose: a pane you are already looking at does not need to
# be announced, an unattended one does.
cmd_notify_blocked() {
    local sid="${3:-}" project="${4:-}"
    _guard_recursion || exit 0
    _config
    _is_on "$ENABLED" || exit 0
    _is_on "$NOTIFY"  || exit 0

    local pane active
    pane="$(_pane_of "$sid")"
    active="$(_active_pane)"
    [[ -n "$pane" && "$pane" == "$active" ]] && { tk_debug "skip: blocked pane is focused"; exit 0; }

    _say_now "${project:-An agent} needs permission."
    # The user's own snippet, if any, gets the same event.
    tk_notify agent-voice blocked "$project" "$sid"
}

# ── menu ──────────────────────────────────────────────────────────────

cmd_toggle() {
    local opt="$1" on="$2" off="${3:-}"
    local cur; cur="$(tk_opt "$opt" "$on")"
    if [[ "$cur" == "$on" ]]; then tk_opt_set "$opt" "$off"; else tk_opt_set "$opt" "$on"; fi
    tk_config_invalidate
}

cmd_cycle_voice() {
    _config
    # Only the six non-novelty English voices installed on a stock macOS.
    local list=(Daniel Samantha Karen Moira Rishi Tessa) i=0 next="Daniel"
    for i in "${!list[@]}"; do
        if [[ "${list[$i]}" == "$VOICE" ]]; then
            next="${list[$(( (i + 1) % ${#list[@]} ))]}"
            break
        fi
    done
    tk_opt_set @agent-voice-voice "$next"
    tk_config_invalidate
    tk_display "voice: $next"
}

cmd_cycle_rate() {
    _config
    local next
    case "$RATE" in 170) next=200 ;; 200) next=240 ;; 240) next=280 ;; *) next=170 ;; esac
    tk_opt_set @agent-voice-rate "$next"
    tk_config_invalidate
    tk_display "rate: $next wpm"
}

cmd_menu() {
    (
    _config
    local self="$SCRIPTS_DIR/voice-wrapper.sh"
    tk_menu_reset
    tk_menu_title " agent-voice "
    tk_menu_item "speaking: $( _is_on "$ENABLED" && printf on || printf off )" \
        "e" "$(tk_menu_cmd "$self" toggle-enabled-reopen)"
    tk_menu_item "scope: $SCOPE" \
        "s" "$(tk_menu_cmd "$self" toggle-scope-reopen)"
    tk_menu_item "permission alerts: $( _is_on "$NOTIFY" && printf on || printf off )" \
        "p" "$(tk_menu_cmd "$self" toggle-notify-reopen)"
    tk_menu_sep
    tk_menu_item "voice: $VOICE" "v" "$(tk_menu_cmd "$self" cycle-voice-reopen)"
    tk_menu_item "rate: $RATE wpm" "r" "$(tk_menu_cmd "$self" cycle-rate-reopen)"
    tk_menu_sep
    tk_menu_item "stop speaking" "BSpace" "$(tk_menu_cmd "$self" stop)"
    tk_menu_item "skip sentence" "Tab" "$(tk_menu_cmd "$self" skip)"
    tk_menu_sep
    tk_menu_quit
    tk_menu_show
    ) || true
}

# ── diagnostics ───────────────────────────────────────────────────────

cmd_status() {
    _config
    local loop child total
    loop="$(_holder)"
    child="$(cat "$CHILD_PID" 2>/dev/null || true)"
    # grep -c prints 0 and exits 1 on no match, so its status is not an error.
    total="$(grep -c . "$QUEUE" 2>/dev/null)" || total=0
    printf 'config   voice %s, %s wpm, %s sentences\n' "$VOICE" "$RATE" "$SENTENCES"
    printf 'gates    enabled %s, scope %s, notify %s\n' "$ENABLED" "$SCOPE" "$NOTIFY"
    printf 'speaker  %s\n' "$( [[ -n "$loop"  ]] && kill -0 "$loop"  2>/dev/null && printf '%s running' "$loop"  || printf idle )"
    printf 'say      %s\n' "$( [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null && printf '%s running' "$child" || printf idle )"
    printf 'cursor   sentence %s of %s\n' "$(cat "$CURSOR" 2>/dev/null || printf 0)" "${total:-0}"
    printf 'dir      %s\n' "$TK_DIR"
}

cmd_doctor() {
    local rc=0
    printf 'tmux-agent-voice, toolkit %s\n\n' "$(tk_lib_version)"
    for c in say jq sqlite3 tmux; do
        if tk_have "$c"; then printf '  ok    %s\n' "$c"; else printf '  FAIL  %s missing\n' "$c"; rc=1; fi
    done
    _config
    if say -v '?' 2>/dev/null | grep -q "^$VOICE "; then
        printf '  ok    voice %s installed\n' "$VOICE"
    else
        printf '  FAIL  voice %s not in say -v ?\n' "$VOICE"; rc=1
    fi
    if [[ -r "$TRACKER_DB" ]]; then
        printf '  ok    tracker db readable\n'
    else
        printf '  warn  no tracker db at %s; scope=active cannot resolve panes\n' "$TRACKER_DB"
    fi
    local wired; wired="$(tk_opt @agent-tracker-on-transition)"
    if [[ "$wired" == *voice.sh* ]]; then
        printf '  ok    wired to @agent-tracker-on-transition\n'
    else
        printf '  FAIL  @agent-tracker-on-transition does not call voice.sh; run install.sh\n'; rc=1
    fi
    # The cache tracker actually reads, which is not the same question as the
    # option being set. An absent cache is reported as absent, not as ok: the
    # earlier form of this check said ok when the file was missing, which is the
    # one answer that proves nothing.
    local cc="${TRACKER_DIR:-$HOME/.tmux-agent-tracker}/config_cache"
    if [[ ! -f "$cc" ]]; then
        printf '  warn  no tracker config cache yet; it is rebuilt on the next hook\n'
    elif grep -q "HOOK_ON_TRANSITION='.*voice.sh" "$cc" 2>/dev/null; then
        printf '  ok    tracker config cache carries the hook\n'
    else
        printf '  FAIL  tracker config cache predates the wiring; rm %s\n' "$cc"; rc=1
    fi
    return "$rc"
}

cmd_demo() {
    cat > "$QUEUE" <<'EOF'
One. The queue is four sentences long and this is the first of them.
Two. Hit skip now and you should land in the middle of sentence three.
Three. This sentence is deliberately long so there is room to interrupt it, and if you are hearing all of it then skip did not fire.
Four. Last one, so stop here proves that silence arrives mid word.
EOF
    _launch "$QUEUE"
    printf 'speaking 4 sentences; try: voice.sh skip   and   voice.sh stop\n'
}

# hook-transition <from> <to> <sid> <project> <summary>
#
# The single entry tracker calls. Dispatch on the destination status: `completed`
# is a finished turn, `blocked` is a permission wait. Every other transition is
# noise for this plugin.
cmd_hook_transition() {
    case "${2:-}" in
        completed) cmd_speak_session "$@" ;;
        blocked)   cmd_notify_blocked "$@" ;;
        *)         exit 0 ;;
    esac
}

case "${1:-}" in
    toggle-enabled-reopen)  cmd_toggle @agent-voice-enabled on off; exec "$SCRIPTS_DIR/voice-wrapper.sh" menu ;;
    toggle-notify-reopen)   cmd_toggle @agent-voice-notify on off; exec "$SCRIPTS_DIR/voice-wrapper.sh" menu ;;
    toggle-scope-reopen)    cmd_toggle @agent-voice-scope active any; exec "$SCRIPTS_DIR/voice-wrapper.sh" menu ;;
    cycle-voice-reopen)     cmd_cycle_voice; exec "$SCRIPTS_DIR/voice-wrapper.sh" menu ;;
    cycle-rate-reopen)      cmd_cycle_rate; exec "$SCRIPTS_DIR/voice-wrapper.sh" menu ;;
    hook-transition) shift; cmd_hook_transition "$@" ;;
    speak-session)   shift; cmd_speak_session "$@" ;;
    notify-blocked)  shift; cmd_notify_blocked "$@" ;;
    speak)           cmd_speak "${2:-}" ;;
    stop)            cmd_stop ;;
    skip)            cmd_skip ;;
    menu)            cmd_menu ;;
    toggle-enabled)  cmd_toggle @agent-voice-enabled on off ;;
    toggle-notify)   cmd_toggle @agent-voice-notify on off ;;
    toggle-scope)    cmd_toggle @agent-voice-scope active any ;;
    cycle-voice)     cmd_cycle_voice ;;
    cycle-rate)      cmd_cycle_rate ;;
    status)          cmd_status ;;
    doctor)          cmd_doctor ;;
    demo)            cmd_demo ;;
    *) printf 'usage: ...' >&2; exit 1 ;;
esac
