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
    assert_contains "$output" "run-shell '"
}
