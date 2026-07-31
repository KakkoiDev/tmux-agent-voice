#!/usr/bin/env bats

setup() {
    command -v expect >/dev/null 2>&1 || skip "expect is required"
    command -v tmux >/dev/null 2>&1 || skip "tmux is required"
    export MENU_SOCKET="agent-voice-menu-$BATS_TEST_NUMBER-$$"
    export VOICE_WRAPPER="$BATS_TEST_DIRNAME/../scripts/voice-wrapper.sh"
    tmux -L "$MENU_SOCKET" -f /dev/null new-session -d -s menu-test -x 80 -y 24
    tmux -L "$MENU_SOCKET" set-option -g prefix C-a
    tmux -L "$MENU_SOCKET" set-environment -g TK_SOCKET "$MENU_SOCKET"
}

teardown() {
    [[ -n "${MENU_SOCKET:-}" ]] && tmux -L "$MENU_SOCKET" kill-server 2>/dev/null || true
}

@test "a menu toggle changes the option and reopens the menu" {
    tmux -L "$MENU_SOCKET" set-option -g @agent-voice-enabled on

    run expect "$BATS_TEST_DIRNAME/fixtures/toggle-menu.exp"

    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output" >&2
        return 1
    fi
    [ "$(tmux -L "$MENU_SOCKET" show-option -gqv @agent-voice-enabled)" = on ]
}
