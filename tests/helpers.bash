# shellcheck shell=bash
# Stubs on PATH: say records what it was asked to speak and sleeps, tmux answers
# options from a file. display-menu is a client overlay that capture-pane cannot
# see, so the menu is asserted through TK_MENU_DRYRUN instead.

setup() {
    TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/tav.XXXXXX")"
    export TESTDIR
    export VOICE_DIR="$TESTDIR/dir"
    export TK_DIR="$VOICE_DIR"
    export SAY_LOG="$TESTDIR/say.log"
    export FAKE_OPTS="$TESTDIR/opts"
    export TRACKER_DB="$TESTDIR/tracker.db"
    export SAY_SLEEP=3
    mkdir -p "$VOICE_DIR" "$TESTDIR/bin"
    : > "$SAY_LOG"
    : > "$FAKE_OPTS"

    cat > "$TESTDIR/bin/say" <<'STUB'
#!/usr/bin/env bash
text=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) shift; [[ "${1:-}" == "-" ]] && text="$(cat)" ;;
        -v|-r) shift ;;
        '?') printf 'Daniel              en_GB    # Hello!\n'; exit 0 ;;
    esac
    shift
done
printf '%s\n' "$text" >> "$SAY_LOG"
sleep "${SAY_SLEEP:-3}"
STUB

    # Faithful to the two *different* calls the library makes. Getting this wrong
    # is silent: tk_opt_bulk passes no key at all, so a stub that keys off the
    # last argument returns nothing, every option falls back to its default, and
    # every gate test passes without ever exercising the option it names.
    #   tk_opt      -> show-option  -gqv <key>   ... one value, bare
    #   tk_opt_bulk -> show-options -g           ... all options, "@name value"
    cat > "$TESTDIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
opts="${FAKE_OPTS:-/dev/null}"
case "${1:-}" in
    show-option)
        key="${!#}"
        # tail, not head: set-option appends, so the last write is current.
        grep -E "^${key}=" "$opts" 2>/dev/null | tail -1 | cut -d= -f2- || true
        ;;
    show-options)
        # Same rendering tmux uses: name, one space, value.
        sed -E 's/=/ /' "$opts" 2>/dev/null || true
        ;;
    set-option) printf '%s=%s\n' "$3" "${4:-}" >> "$opts" ;;
    display-message) printf '%s' "${FAKE_ACTIVE_PANE:-%9}" ;;
esac
exit 0
STUB
    chmod +x "$TESTDIR/bin/say" "$TESTDIR/bin/tmux"
    export PATH="$TESTDIR/bin:$PATH"

    VOICE="$BATS_TEST_DIRNAME/../scripts/voice.sh"
    export VOICE
}

teardown() {
    [[ -n "${TESTDIR:-}" ]] && "$BATS_TEST_DIRNAME/../scripts/voice.sh" stop >/dev/null 2>&1 || true
    [[ -n "${TESTDIR:-}" ]] && rm -rf "$TESTDIR"
}

# grep -c prints its count and exits 1 when the count is zero.
say_calls() { local n; n="$(grep -c . "$SAY_LOG" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# Poll, never sleep a fixed interval. voice.sh sources twelve library files and
# does one cold tk_config_load fork before it speaks, and the hook path pays that
# twice because it re-execs itself detached. Measured at 1 to 2 seconds on this
# machine, so any fixed sleep is a coin flip.
TK_WAIT="${TK_WAIT:-8}"

# wait_file <path> - true once it exists.
wait_file() {
    local i=0
    while [[ ! -e "$1" ]]; do
        i=$((i + 1)); [[ "$i" -gt $(( TK_WAIT * 10 )) ]] && { printf 'timeout waiting for %s\n' "$1" >&2; return 1; }
        sleep 0.1
    done
    return 0
}

# wait_says <n> - true once at least n utterances have been logged.
wait_says() {
    local i=0
    while [[ "$(say_calls)" -lt "$1" ]]; do
        i=$((i + 1)); [[ "$i" -gt $(( TK_WAIT * 10 )) ]] && { printf 'timeout waiting for %s utterance(s), have %s\n' "$1" "$(say_calls)" >&2; return 1; }
        sleep 0.1
    done
    return 0
}

# wait_grep <pattern> <file> - true once the pattern appears.
wait_grep() {
    local i=0
    while ! grep -qF -- "$1" "$2" 2>/dev/null; do
        i=$((i + 1)); [[ "$i" -gt $(( TK_WAIT * 10 )) ]] && { printf 'timeout waiting for [%s] in %s\n' "$1" "$2" >&2; return 1; }
        sleep 0.1
    done
    return 0
}

# settle - give a guard the same budget a speaker would have needed, so
# "spoke nothing" means refused rather than merely slower than the assertion.
settle() { sleep 3; }

opt_set() { printf '%s=%s\n' "$1" "$2" >> "$FAKE_OPTS"; }

# A transcript with two turns, a sidechain entry, a fence, a table, an absolute
# path, a harness marker, an underscore identifier and a version number.
fixture() {
    local f="$TESTDIR/t.jsonl"
    {
      printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"q1"}}'
      printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"An older turn that must not be spoken."}]}}'
      printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"q2"}}'
      printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","content":"ignored"}]}}'
      printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"SUBAGENT LEAKAGE must not be spoken."}]}}'
      printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"[canary_cry] Running tmux 3.5a in en_US. Bug is in /Users/x/Code/y/auth.sh and it is real.\n\n```sh\nrm -rf /\n```\n\n| c | c |\n|---|---|\n\n## Heading\n\n- Third with **bold** and `ticks`. Fourth lands here. Fifth must be cut."}]}}'
    } > "$f"
    printf '%s' "$f"
}

# A pi-format transcript (the shape extract-pi.sh reads): two turns, an interim
# narration before a tool call, a fence, a table, an absolute path, a harness
# marker, an underscore identifier and a version number - the same probes as the
# claude fixture, plus the two pi-only ones (older turn, interim narration).
# Echoes the transcript path; the session dir is dirname.
pi_fixture() {
    local dir="$TESTDIR/.pi/agent/sessions/--w--"
    mkdir -p "$dir"
    local f="$dir/2026-07-31T00-00-00-000Z_pi1.jsonl"
    {
      printf '%s\n' '{"type":"session","version":3,"id":"pi1","timestamp":"2026-07-31T00:00:00.000Z","cwd":"/Users/x/proj"}'
      printf '%s\n' '{"type":"message","id":"u1","parentId":"pi1","timestamp":"2026-07-31T00:00:01Z","message":{"role":"user","content":[{"type":"text","text":"q1"}]}}'
      printf '%s\n' '{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-07-31T00:00:02Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"internal"},{"type":"text","text":"An older turn that must not be spoken."}]}}'
      printf '%s\n' '{"type":"message","id":"u2","parentId":"a1","timestamp":"2026-07-31T00:00:03Z","message":{"role":"user","content":[{"type":"text","text":"q2"}]}}'
      printf '%s\n' '{"type":"message","id":"a2","parentId":"u2","timestamp":"2026-07-31T00:00:04Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"internal"},{"type":"text","text":"Interim narration before a tool call."},{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"true"}}]}}'
      printf '%s\n' '{"type":"message","id":"r1","parentId":"a2","timestamp":"2026-07-31T00:00:05Z","message":{"role":"toolResult","toolCallId":"c1","toolName":"bash","content":[{"type":"text","text":""}]}}'
      printf '%s\n' '{"type":"message","id":"a3","parentId":"r1","timestamp":"2026-07-31T00:00:06Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"internal"},{"type":"text","text":"[canary_pi] Running tmux 3.5a in en_US. Bug is in /Users/x/Code/y/auth.sh and it is real.\n\n```sh\nrm -rf /\n```\n\n| c | c |\n|---|---|\n\n## Heading\n\n- Third with **bold** and `ticks`. Fourth lands here. Fifth must be cut."}]}}'
    } > "$f"
    printf '%s' "$f"
}

assert_eq()       { if [[ "$1" == "$2" ]]; then return 0; else printf 'want [%s] got [%s]\n' "$2" "$1" >&2; return 1; fi; }
assert_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then return 0; else printf 'missing [%s] in [%s]\n' "$2" "$1" >&2; return 1; fi; }
assert_absent()   { if printf '%s' "$1" | grep -qF -- "$2"; then printf 'found [%s]\n' "$2" >&2; return 1; else return 0; fi; }
assert_alive()    { if kill -0 "$1" 2>/dev/null; then return 0; else printf 'pid %s dead\n' "$1" >&2; return 1; fi; }
assert_dead()     { if kill -0 "$1" 2>/dev/null; then printf 'pid %s alive\n' "$1" >&2; return 1; else return 0; fi; }
