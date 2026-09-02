# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Sharp edges that cost real time

- **Two transcript extractors, one prose engine.** `scripts/extract.sh` owns
  `~/.claude/**/*.jsonl`; `scripts/extract-pi.sh` owns
  `~/.pi/agent/sessions/**/*.jsonl` and *delegates* its prose rules + sentence
  split to extract.sh. Changing extract.sh's rules changes Pi's speech too.
  Details: `HANDOFF.md` Map + decisions.
- **Harness dispatch has a backstop.** `_harness_of` in `scripts/voice.sh` reads
  `sessions.agent_client` from tracker.db, but tracker's pi detection pattern
  (`/.pi/sessions/`) is stale vs the real `~/.pi/agent/sessions/` layout, so
  pi sessions are often recorded as `agent_client='claude'`. Dispatch therefore
  also checks the session_id shape (pi ids are full transcript paths). Do not
  "simplify" that away until the tracker pattern is fixed upstream.
- **`lib/menu.sh` is a vendored subtree with two local divergences.** Both are
  already in tmux-toolkit `main`, but consumers subtree from its `dist` branch
  and that branch is still the 0.2.0 split, so neither can be pulled in yet:
  `tk_menu_show` ends `|| true` so menu dismissal does not surface as
  "returned 1" (HANDOFF decision 8), and `tk_menu_cmd` emits
  `run-shell "<one argument>"` so tmux does not reject the menu action as
  "too many arguments" (`f345187`; `tests/voice.bats` and `tests/menu-e2e.bats`
  both assert it). Re-apply both after any `git subtree pull` of tmux-toolkit.
- **`lib/.checksum` is generated, never hand-written.** It is the fingerprint
  CI's drift gate compares against, so after any `lib/` change regenerate it
  with the gate's own pipeline:
  `find lib -name '*.sh' | sort | xargs shasum | shasum | cut -d' ' -f1 > lib/.checksum`.
  A hand-typed value that matched no tree at all failed every CI run, master
  included, from 2026-07-31 until it was regenerated.
- **Tests override real paths via env:** `TRACKER_DB` and `PI_SESSIONS_ROOT`
  are both settable; the bats suite stubs `say`/`tmux` on PATH. Run
  `bats tests/` and again under `/bin/bash` (macOS bash 3.2); the menu E2E test
  also requires `expect` and drives a real isolated tmux client;
  shellcheck: `shellcheck -S warning -x scripts/*.sh install.sh uninstall.sh
  agent-voice.tmux bin/*`.
- **`A && B && C` under `set -e` is safe only because B is not syntactically
  last.** Bash's errexit exemption for `&&`/`||` list members is positional in
  the source, not "did it actually run": `true && false && echo x` survives
  (`false` isn't last), but `true && false` alone does not. This codebase
  leans on that pattern throughout (`voice.sh`'s `ja_ok` gate, guard clauses);
  never collapse a three-link chain to two without checking which link would
  become last.
- **The bats `say` stub must special-case `say -v '?'` before its normal arg
  loop.** A `case "$1" in ... '?') ... ;; esac` inside the arg-consuming while
  loop never matches, because `-v`'s branch already shifted `'?'` out from
  under `$1` on the same iteration; `tests/helpers.bash` checks
  `"${1:-}"/"${2:-}"` up front instead.
- **Japanese speech is automatic detection plus a chosen voice, two separate
  things.** `_is_japanese` (`scripts/voice.sh`) scores each queued sentence
  and `cmd_speak` swaps to `$VOICE_JA` transparently when it crosses the
  threshold, falling back to `$VOICE` if `VOICE_JA` isn't installed; this part
  has no toggle and never will, since a sentence is or isn't Japanese, there
  is nothing to switch. What the menu's `japanese voice:` row (`cmd_menu`,
  bound to `j`) controls is which installed voice gets used for the sentences
  detection already picked out, cycling via `_ja_installed_voices` (`say -v
  '?'` filtered to `ja*` locales, not a hardcoded list, since the roster
  varies by macOS version and what Spoken Content has downloaded). The row
  renders `none installed` rather than disappearing when that list is empty,
  and cycling then falls back to `Kyoko` so the option is sane once one is
  installed.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
