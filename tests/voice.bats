#!/usr/bin/env bats
load helpers

# ── extraction ────────────────────────────────────────────────────────

@test "extracts only the final assistant turn" {
    run "$BATS_TEST_DIRNAME/../scripts/extract.sh" "$(fixture)" 4
    assert_eq "$status" 0
    assert_absent "$output" "older turn"
}

@test "excludes subagent sidechain output" {
    run "$BATS_TEST_DIRNAME/../scripts/extract.sh" "$(fixture)" 4
    assert_absent "$output" "SUBAGENT LEAKAGE"
}

@test "drops fenced code, tables and headings" {
    run "$BATS_TEST_DIRNAME/../scripts/extract.sh" "$(fixture)" 4
    assert_absent "$output" "rm -rf"
    assert_absent "$output" "| c |"
    assert_absent "$output" "Heading"
}

@test "collapses an absolute path to its basename" {
    run "$BATS_TEST_DIRNAME/../scripts/extract.sh" "$(fixture)" 4
    assert_absent   "$output" "/Users/x"
    assert_contains "$output" "auth.sh"
}

@test "drops a leading harness marker instead of speaking it" {
    run "$BATS_TEST_DIRNAME/../scripts/extract.sh" "$(fixture)" 4
    assert_absent "$output" "canary"
}

@test "an underscore becomes a space, not nothing" {
    run "$BATS_TEST_DIRNAME/../scripts/extract.sh" "$(fixture)" 4
    assert_contains "$output" "en US"
    assert_absent   "$output" "enUS"
}

@test "a version number does not end a sentence" {
    run "$BATS_TEST_DIRNAME/../scripts/extract.sh" "$(fixture)" 4
    assert_contains "$output" "tmux 3.5a in"
}

@test "honours the sentence cap" {
    run "$BATS_TEST_DIRNAME/../scripts/extract.sh" "$(fixture)" 4
    assert_eq "$(printf '%s\n' "$output" | grep -c .)" 4
    assert_absent "$output" "Fifth"
}

@test "strips markdown emphasis and backticks" {
    run "$BATS_TEST_DIRNAME/../scripts/extract.sh" "$(fixture)" 4
    assert_absent "$output" '**'
    assert_absent "$output" '`'
}

# ── pi extraction ────────────────────────────────────────────────────

@test "pi: extracts only the final assistant turn" {
    run "$BATS_TEST_DIRNAME/../scripts/extract-pi.sh" "$(dirname "$(pi_fixture)")" 4
    assert_eq "$status" 0
    assert_absent "$output" "older turn"
}

@test "pi: drops interim narration before tool calls, keeps only the answer" {
    run "$BATS_TEST_DIRNAME/../scripts/extract-pi.sh" "$(dirname "$(pi_fixture)")" 4
    assert_absent "$output" "Interim narration"
}

@test "pi: applies the same prose rules as claude" {
    run "$BATS_TEST_DIRNAME/../scripts/extract-pi.sh" "$(dirname "$(pi_fixture)")" 4
    assert_absent   "$output" "rm -rf"
    assert_absent   "$output" "| c |"
    assert_absent   "$output" "Heading"
    assert_absent   "$output" "canary"
    assert_absent   "$output" "/Users/x"
    assert_contains "$output" "auth.sh"
    assert_contains "$output" "en US"
    assert_contains "$output" "tmux 3.5a in"
}

@test "pi: honours the sentence cap" {
    run "$BATS_TEST_DIRNAME/../scripts/extract-pi.sh" "$(dirname "$(pi_fixture)")" 4
    assert_eq "$(printf '%s\n' "$output" | grep -c .)" 4
    assert_absent "$output" "Fifth"
}

@test "pi: a session with no finished answer speaks nothing" {
    d="$TESTDIR/pi-mid"; mkdir -p "$d"
    printf '%s\n' \
      '{"type":"session","version":3,"id":"m","timestamp":"2026-07-31T00:00:00.000Z","cwd":"/x"}' \
      '{"type":"message","id":"u","message":{"role":"user","content":[{"type":"text","text":"q"}]}}' \
      '{"type":"message","id":"a","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"toolCall","id":"c","name":"bash","arguments":{"command":"true"}}]}}' \
      > "$d/2026-07-31T00-00-00-000Z_mid.jsonl"
    run "$BATS_TEST_DIRNAME/../scripts/extract-pi.sh" "$d" 4
    assert_eq "$status" 0
    assert_eq "$output" ""
}

# ── gates ─────────────────────────────────────────────────────────────

@test "the recursion guard refuses to speak" {
    f="$(fixture)"
    CLAUDE_CONFIG_DIR="$TESTDIR/cc" ; mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"
    cp "$f" "$CLAUDE_CONFIG_DIR/projects/p/sid1.jsonl"
    CLAUDE_VOICE_SPEAKING=1 CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
        "$VOICE" hook-transition working completed sid1 proj s || true
    settle
    assert_eq "$(say_calls)" 0
}

@test "disabled refuses to speak" {
    opt_set @agent-voice-enabled off
    f="$(fixture)"; mkdir -p "$TESTDIR/cc/projects/p"; cp "$f" "$TESTDIR/cc/projects/p/sid1.jsonl"
    CLAUDE_CONFIG_DIR="$TESTDIR/cc" "$VOICE" hook-transition working completed sid1 proj s || true
    settle
    assert_eq "$(say_calls)" 0
}

@test "a transition that is neither completed nor blocked is ignored" {
    f="$(fixture)"; mkdir -p "$TESTDIR/cc/projects/p"; cp "$f" "$TESTDIR/cc/projects/p/sid1.jsonl"
    CLAUDE_CONFIG_DIR="$TESTDIR/cc" "$VOICE" hook-transition idle working sid1 proj s || true
    settle
    assert_eq "$(say_calls)" 0
}

@test "a missing transcript is not an error and speaks nothing" {
    CLAUDE_CONFIG_DIR="$TESTDIR/empty" "$VOICE" hook-transition working completed nosuch proj s
    settle
    assert_eq "$(say_calls)" 0
}

@test "scope=any speaks without a pane match" {
    opt_set @agent-voice-scope any
    f="$(fixture)"; mkdir -p "$TESTDIR/cc/projects/p"; cp "$f" "$TESTDIR/cc/projects/p/sid1.jsonl"
    SAY_SLEEP=1 CLAUDE_CONFIG_DIR="$TESTDIR/cc" "$VOICE" hook-transition working completed sid1 proj s
    wait_says 1
}

@test "scope=active stays silent when the pane is not focused" {
    # No tracker db row, so the pane cannot resolve, which must fail closed.
    f="$(fixture)"; mkdir -p "$TESTDIR/cc/projects/p"; cp "$f" "$TESTDIR/cc/projects/p/sid1.jsonl"
    FAKE_ACTIVE_PANE=%3 CLAUDE_CONFIG_DIR="$TESTDIR/cc" \
        "$VOICE" hook-transition working completed sid1 proj s
    settle
    assert_eq "$(say_calls)" 0
}

@test "a blocked agent in an unfocused pane is announced" {
    opt_set @agent-voice-scope any
    SAY_SLEEP=1 FAKE_ACTIVE_PANE=%3 "$VOICE" hook-transition working blocked sid1 accounting s
    wait_grep "accounting needs permission" "$SAY_LOG"
}

# ── pi dispatch ───────────────────────────────────────────────────────

# A tracker row for the fixture: agent_client=pi, session_id is the full
# transcript path (the shape tracker stores for pi), pane matches.
_pi_tracker_row() {
    local sid="$1" client="$2"
    sqlite3 "$TRACKER_DB" "CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY, status TEXT, cwd TEXT, project_name TEXT,
        agent_client TEXT, tmux_pane TEXT);
        INSERT INTO sessions VALUES ('$sid','completed','$TESTDIR/w','proj','$client','%9');"
}

@test "a pi harness speaks its transcript through extract-pi.sh" {
    opt_set @agent-voice-scope any
    sid="$(pi_fixture)"
    _pi_tracker_row "$sid" pi
    SAY_SLEEP=1 "$VOICE" hook-transition working completed "$sid" proj s
    wait_says 1
    assert_contains "$(cat "$SAY_LOG")" "en US"
    assert_absent   "$(cat "$SAY_LOG")" "Interim narration"
}

@test "a pi harness with a non-path session id resolves its session dir by cwd" {
    opt_set @agent-voice-scope any
    # dirname-of-sid cannot fire (the id is a uuid), so the tracker cwd must
    # map to the pi session dir; the decoy dir proves the scan picks the match.
    root="$TESTDIR/piroot"
    mkdir -p "$root/decoy"
    printf '%s\n' '{"type":"session","version":3,"id":"d","timestamp":"2026-07-31T00:00:00.000Z","cwd":"/elsewhere"}' \
        > "$root/decoy/2026-07-31T00-00-00-000Z_decoy.jsonl"
    mkdir -p "$root/--w--"
    cp "$(pi_fixture)" "$root/--w--/2026-07-31T00-00-00-000Z_pi1.jsonl"
    # The fixture's session line records cwd /Users/x/proj; the tracker row
    # must agree for the scan to match. The derived dir name --Users-x-proj--
    # does not exist, so the scan is the only route.
    _pi_tracker_row "uuid-not-a-path" pi
    sqlite3 "$TRACKER_DB" "UPDATE sessions SET cwd='/Users/x/proj' WHERE session_id='uuid-not-a-path';"
    SAY_SLEEP=1 PI_SESSIONS_ROOT="$root" "$VOICE" hook-transition working completed "uuid-not-a-path" proj s
    wait_says 1
    assert_contains "$(cat "$SAY_LOG")" "en US"
}

@test "a claude harness keeps using the claude transcript" {
    opt_set @agent-voice-scope any
    f="$(fixture)"; mkdir -p "$TESTDIR/cc/projects/p"; cp "$f" "$TESTDIR/cc/projects/p/sid1.jsonl"
    _pi_tracker_row sid1 claude
    SAY_SLEEP=1 CLAUDE_CONFIG_DIR="$TESTDIR/cc" "$VOICE" hook-transition working completed sid1 proj s
    wait_says 1
    assert_contains "$(cat "$SAY_LOG")" "en US"
}

@test "the recursion guard refuses to speak a pi turn" {
    sid="$(pi_fixture)"
    _pi_tracker_row "$sid" pi
    CLAUDE_VOICE_SPEAKING=1 "$VOICE" hook-transition working completed "$sid" proj s || true
    settle
    assert_eq "$(say_calls)" 0
}

# ── interrupt ─────────────────────────────────────────────────────────

@test "skip advances exactly one sentence and the loop survives" {
    printf 'One.\nTwo.\nThree.\nFour.\n' > "$TESTDIR/q.txt"
    SAY_SLEEP=5 "$VOICE" speak "$TESTDIR/q.txt" &
    loop=$!
    wait_says 1
    wait_file "$TK_DIR/child.pid"
    assert_eq "$(cat "$TK_DIR/cursor")" 1
    child="$(cat "$TK_DIR/child.pid")"
    "$VOICE" skip
    wait_says 2
    assert_dead  "$child"
    assert_alive "$loop"
    assert_eq "$(cat "$TK_DIR/cursor")" 2
    "$VOICE" stop
    wait "$loop" 2>/dev/null || true
}

@test "stop silences immediately and leaves no state behind" {
    printf 'One.\nTwo.\nThree.\nFour.\n' > "$TESTDIR/q.txt"
    SAY_SLEEP=5 "$VOICE" speak "$TESTDIR/q.txt" &
    loop=$!
    wait_says 1
    wait_file "$TK_DIR/child.pid"
    child="$(cat "$TK_DIR/child.pid")"
    "$VOICE" stop
    sleep 1
    assert_dead "$child"
    assert_dead "$loop"
    assert_eq "$( [[ -e "$TK_DIR/child.pid" ]] && printf present || printf gone )" gone
    assert_eq "$( [[ -d "$TK_DIR/.lock.speaker" ]] && printf held || printf free )" free
    assert_eq "$(say_calls)" 1
    wait "$loop" 2>/dev/null || true
}

@test "stop resets the cursor so status cannot report a killed queue" {
    printf 'One.\nTwo.\nThree.\nFour.\n' > "$TESTDIR/q.txt"
    SAY_SLEEP=5 "$VOICE" speak "$TESTDIR/q.txt" &
    loop=$!
    wait_says 1
    "$VOICE" skip; wait_says 2
    assert_eq "$(cat "$TK_DIR/cursor")" 2
    "$VOICE" stop
    # Immediately, in the same breath as the kill. A reset that waits for the
    # next speaker's process to boot is a second of wrong output, which is the
    # whole window this guards.
    assert_eq "$(cat "$TK_DIR/cursor")" 0
    wait "$loop" 2>/dev/null || true
}

@test "a second speaker does not start while one holds the lock" {
    printf 'One.\nTwo.\n' > "$TESTDIR/q.txt"
    SAY_SLEEP=5 "$VOICE" speak "$TESTDIR/q.txt" &
    loop=$!
    wait_says 1
    "$VOICE" speak "$TESTDIR/q.txt"     # returns immediately, speaks nothing
    assert_eq "$(say_calls)" 1
    "$VOICE" stop
    wait "$loop" 2>/dev/null || true
}

# ── japanese voice ───────────────────────────────────────────────────

@test "a japanese sentence is detected" {
    run "$VOICE" is-japanese "全て日本語で書かれた文章です。"
    assert_eq "$status" 0
}

@test "an english sentence is not detected as japanese" {
    run "$VOICE" is-japanese "Hello world, this is English."
    assert_eq "$status" 1
}

@test "a sentence with a PR URL is not flipped to japanese by a short kana clause" {
    # The URL's latin characters dominate the ratio, so the sentence keeps the
    # english voice rather than switching mid-sentence - the documented tradeoff.
    run "$VOICE" is-japanese "PRを開きました: https://github.com/foo/bar/pull/123"
    assert_eq "$status" 1
}

@test "a mostly-japanese sentence with an embedded identifier still counts as japanese" {
    run "$VOICE" is-japanese "全て日本語で書かれた文章の中に auth.sh が混ざっています。"
    assert_eq "$status" 0
}

@test "an empty string is not japanese" {
    run "$VOICE" is-japanese ""
    assert_eq "$status" 1
}

@test "a japanese and an english sentence in the same queue speak in different voices" {
    opt_set @agent-voice-voice-ja Kyoko
    printf 'Hello world, this is English.\n全て日本語で書かれた文章です。\n' > "$TESTDIR/q.txt"
    SAY_SLEEP=0.2 "$VOICE" speak "$TESTDIR/q.txt"
    wait_says 2
    assert_eq "$(sed -n 1p "$SAY_VOICE_LOG")" "Daniel"
    assert_eq "$(sed -n 2p "$SAY_VOICE_LOG")" "Kyoko"
}

@test "a missing japanese voice degrades the japanese sentence to the default voice" {
    opt_set @agent-voice-voice-ja "NoSuchVoice"
    printf '全て日本語で書かれた文章です。\n' > "$TESTDIR/q.txt"
    SAY_SLEEP=0.2 "$VOICE" speak "$TESTDIR/q.txt"
    wait_says 1
    assert_eq "$(cat "$SAY_VOICE_LOG")" "Daniel"
}

@test "doctor reports the default japanese voice as installed" {
    run "$VOICE" doctor
    assert_contains "$output" "ok    japanese voice Kyoko installed"
}

@test "doctor warns, but does not fail on account of it, when the configured japanese voice is missing" {
    run "$VOICE" doctor
    local baseline_status="$status"

    opt_set @agent-voice-voice-ja "NoSuchVoice"
    rm -f "$TK_DIR/config_cache"
    run "$VOICE" doctor
    assert_contains "$output" "warn  japanese voice NoSuchVoice not in say -v ?"
    assert_absent   "$output" "FAIL  japanese"
    # Same rc as the baseline run: the missing-voice check adds a warn line,
    # not a new FAIL that would flip an otherwise-clean doctor run to failing.
    assert_eq "$status" "$baseline_status"
}

# ── menu ──────────────────────────────────────────────────────────────

# Canary. tk_config_load reads options through tk_opt_bulk, which passes no key
# to `show-options -g`. A stub that answers only keyed lookups returns nothing,
# every option silently falls back to its default, and every gate test above
# passes while exercising nothing. This test fails the moment that happens.
@test "an option set in the test actually reaches the code" {
    opt_set @agent-voice-voice Karen
    opt_set @agent-voice-rate 240
    run env TK_MENU_DRYRUN=1 "$VOICE" menu
    assert_contains "$output" "voice: Karen"
    assert_contains "$output" "rate: 240 wpm"
}

@test "the menu builds a well-formed argument vector" {
    run env TK_MENU_DRYRUN=1 "$VOICE" menu
    assert_eq "$status" 0
    assert_contains "$output" "-T"
    assert_contains "$output" " agent-voice "
    assert_contains "$output" "voice: Daniel"
    assert_contains "$output" "rate: 200 wpm"
}

@test "menu rows come in triples so tmux cannot mis-parse them" {
    # Written to a file, not through $output: command substitution strips
    # trailing newlines, and the last menu field is deliberately empty, so
    # $output loses a row and the arithmetic silently shifts.
    env TK_MENU_DRYRUN=1 "$VOICE" menu > "$TESTDIR/menu.txt"
    n=$(wc -l < "$TESTDIR/menu.txt" | tr -d ' ')
    # Two leading args are -T and the title; the rest must divide by three.
    assert_eq "$(( (n - 2) % 3 ))" 0
}

@test "a menu command is single-quoted so a path with a space survives" {
    run env TK_MENU_DRYRUN=1 "$VOICE" menu
    assert_contains "$output" "run-shell \"'"
}
