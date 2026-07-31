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
- **`lib/menu.sh` is a vendored subtree with one local divergence:**
  `tk_menu_show` ends `|| true` so menu dismissal does not surface as
  "returned 1". Re-apply after any `git subtree pull` of tmux-toolkit
  (HANDOFF decision 8).
- **Tests override real paths via env:** `TRACKER_DB` and `PI_SESSIONS_ROOT`
  are both settable; the bats suite stubs `say`/`tmux` on PATH. Run
  `bats tests/` (33 tests) and again under `/bin/bash` (macOS bash 3.2);
  shellcheck: `shellcheck -S warning -x scripts/*.sh install.sh uninstall.sh
  agent-voice.tmux bin/*`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
