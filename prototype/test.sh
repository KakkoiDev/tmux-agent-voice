#!/usr/bin/env bash
# test.sh - offline proof that the mechanism works. No audio, no network.
#
# say(1) and tmux(1) are replaced by stubs on PATH: say logs the text it was
# given and sleeps, tmux answers options from a file. Every assertion is a
# function call, because on bash 3.2 a bare [[ ]] does not trip set -e unless
# it is the last statement in the body.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
assert_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing [$3])"; fi; }
assert_absent()   { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (found [$3])"; else ok "$1"; fi; }
assert_nonempty() { if [[ -n "${2//[[:space:]]/}" ]]; then ok "$1"; else bad "$1 (empty)"; fi; }
assert_alive()    { if kill -0 "$2" 2>/dev/null; then ok "$1"; else bad "$1 (pid $2 dead)"; fi; }
assert_dead()     { if kill -0 "$2" 2>/dev/null; then bad "$1 (pid $2 alive)"; else ok "$1"; fi; }

# ── stubs ─────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/say" <<'STUB'
#!/usr/bin/env bash
text=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) shift; [[ "${1:-}" == "-" ]] && text="$(cat)" ;;
        -v|-r) shift ;;
    esac
    shift
done
printf '%s\n' "$text" >> "$SAY_LOG"
sleep "${SAY_SLEEP:-3}"
STUB
cat > "$TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    show-option)
        for a in "$@"; do :; done
        key="${!#}"
        grep -E "^${key}=" "${FAKE_OPTS:-/dev/null}" 2>/dev/null | head -1 | cut -d= -f2- || true
        ;;
    display-message) printf '%s' "${FAKE_ACTIVE_PANE:-%9}" ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/say" "$TMP/bin/tmux"
export PATH="$TMP/bin:$PATH"
export FAKE_OPTS="$TMP/opts"; : > "$FAKE_OPTS"
export SAY_LOG="$TMP/say.log";  : > "$SAY_LOG"
export TA_STATE="$TMP/state"
# grep -c prints 0 and exits 1 on no match, so `|| echo 0` would emit two lines.
say_calls() { local n; n="$(grep -c . "$SAY_LOG" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
reset() { : > "$SAY_LOG"; rm -rf "$TA_STATE"; mkdir -p "$TA_STATE"; }

# ── fixture ───────────────────────────────────────────────────────────
# Two turns, a sidechain assistant entry, a code fence, a table, an absolute
# path and a version number that must not be mistaken for a sentence end.
FIX="$TMP/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"first question"}}'
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"An older turn that must not be spoken."}]}}'
  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"second question"}}'
  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","content":"ignored"}]}}'
  printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"SUBAGENT LEAKAGE must not be spoken."}]}}'
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"[canary_cry] Running tmux 3.5a here in en_US. The bug is in /Users/someone/Code/thing/auth.sh and it is real.\n\n```sh\nrm -rf /\n```\n\n| col | col |\n|---|---|\n\n## Heading\n\n- Second point with **bold** and `backticks`. Third sentence lands here. Fourth one too. Fifth must be cut."}]}}'
} > "$FIX"

echo "extract"
out="$("$HERE/extract.sh" "$FIX" 4)"
assert_nonempty  "produces output"                     "$out"
assert_absent    "older turn excluded"                 "$out" "older turn"
assert_absent    "sidechain excluded"                  "$out" "SUBAGENT LEAKAGE"
assert_absent    "code fence body dropped"             "$out" "rm -rf"
assert_absent    "table rows dropped"                  "$out" "| col |"
assert_absent    "headings dropped"                    "$out" "Heading"
assert_absent    "absolute path shortened"             "$out" "/Users/someone"
assert_contains  "path basename kept"                  "$out" "auth.sh"
assert_absent    "backticks stripped"                  "$out" '`'
assert_absent    "bold markers stripped"               "$out" '**'
assert_contains  "version not split"                   "$out" "tmux 3.5a here"
assert_absent    "harness marker dropped"              "$out" "canary"
assert_contains  "underscore becomes a space"          "$out" "en US"
assert_absent    "underscore not deleted outright"     "$out" "enUS"
assert_eq        "capped at 4 sentences"               "$(printf '%s\n' "$out" | grep -c .)" "4"
assert_absent    "fifth sentence cut"                  "$out" "Fifth"

echo
echo "hook guards"
reset
printf '%s' '{"transcript_path":"'"$FIX"'"}' | CLAUDE_VOICE_SPEAKING=1 "$HERE/speak.sh" hook || true
assert_eq "recursion guard: zero say calls" "$(say_calls)" "0"

reset
printf '@voice-enabled=off\n' > "$FAKE_OPTS"
printf '%s' '{"transcript_path":"'"$FIX"'"}' | TMUX_PANE=%9 "$HERE/speak.sh" hook || true
assert_eq "disabled: zero say calls" "$(say_calls)" "0"

reset
: > "$FAKE_OPTS"
printf '%s' '{"transcript_path":"'"$FIX"'"}' | TMUX_PANE=%3 FAKE_ACTIVE_PANE=%9 "$HERE/speak.sh" hook || true
assert_eq "inactive pane: zero say calls" "$(say_calls)" "0"

reset
printf '%s' '{"transcript_path":"/nope/missing.jsonl"}' | TMUX_PANE=%9 "$HERE/speak.sh" hook || true
assert_eq "missing transcript: zero say calls" "$(say_calls)" "0"

reset
printf '%s' '{"transcript_path":"'"$FIX"'"}' | TMUX_PANE=%9 SAY_SLEEP=1 "$HERE/speak.sh" hook || true
sleep 1
assert_eq "active pane: speaks" "$( [[ "$(say_calls)" -ge 1 ]] && echo yes || echo no )" "yes"
"$HERE/speak.sh" stop || true

echo
echo "skip and stop"
reset
printf 'Sentence one.\nSentence two.\nSentence three.\nSentence four.\n' > "$TMP/q.txt"
SAY_SLEEP=5 "$HERE/speak.sh" speak "$TMP/q.txt" &
loop=$!
sleep 1
assert_eq    "cursor at 1"        "$(cat "$TA_STATE/cursor" 2>/dev/null)" "1"
assert_eq    "one say so far"     "$(say_calls)"                          "1"
child="$(cat "$TA_STATE/child.pid" 2>/dev/null)"
"$HERE/speak.sh" skip
sleep 1
assert_dead  "skip killed the say"  "$child"
assert_alive "skip kept the loop"   "$loop"
assert_eq    "cursor advanced by 1" "$(cat "$TA_STATE/cursor" 2>/dev/null)" "2"
assert_eq    "two says so far"      "$(say_calls)"                          "2"

child2="$(cat "$TA_STATE/child.pid" 2>/dev/null)"
"$HERE/speak.sh" stop
sleep 1
assert_dead "stop killed the say"  "$child2"
assert_dead "stop killed the loop" "$loop"
assert_eq   "no say left running"  "$(pgrep -f "$TMP/bin/say" >/dev/null 2>&1 && echo some || echo none)" "none"
assert_eq   "speaker.pid cleared"  "$( [[ -e "$TA_STATE/speaker.pid" ]] && echo present || echo gone )" "gone"
assert_eq   "child.pid cleared"    "$( [[ -e "$TA_STATE/child.pid" ]] && echo present || echo gone )"   "gone"
assert_eq   "stopped before end"   "$(say_calls)" "2"
wait "$loop" 2>/dev/null || true

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
