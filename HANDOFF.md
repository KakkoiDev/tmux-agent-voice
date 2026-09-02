# Handoff

Written for whoever picks this up next, including a future me with no memory of
it. Read this before touching anything; it is the only place the dead ends are
written down, and two of them measured worse than the thing they replaced.

State: **working and installed on the author's machine.** 43 bats tests green
(also under bash 3.2), shellcheck clean, `doctor` all ok, audio verified by ear.

## What it is, in one paragraph

A tmux plugin that speaks the last four sentences of a finished agent turn
(Claude Code or Pi) through macOS `say`, in the voice `Daniel`, at 200 wpm, and
only for the pane you are looking at. `prefix + Tab` abandons the current
sentence, `prefix + BSpace` silences everything mid-word, `prefix + V` opens a
`display-menu` of toggles. A blocked agent in a pane you are *not* looking at
announces itself. No LLM in the path. `~/.claude/settings.json` is never
touched.

## Map

| Path | What it owns |
|---|---|
| `scripts/voice.sh` | everything: dispatch, guards, queue loop, menu, doctor |
| `scripts/extract.sh` | the **only** file that reads `~/.claude/**/*.jsonl`; owns the prose rules and sentence split for both harnesses |
| `scripts/extract-pi.sh` | the **only** file that reads `~/.pi/agent/sessions/**/*.jsonl`; turns the final Pi answer into a Claude-format line and hands it to `extract.sh` |
| `agent-voice.tmux` | TPM entry, three key bindings |
| `install.sh` / `uninstall.sh` | CLI symlink plus tracker wiring, and its reverse |
| `tests/voice.bats` | 43 tests: 14 extraction, 11 gates, 4 interrupt, 9 japanese voice, 4 menu, 1 vendoring |
| `tests/helpers.bash` | stub `say`, stub `tmux`, polling waiters |
| `lib/` | tmux-toolkit 0.2.0, vendored by `git subtree`. **Do not edit in place.** See the menu-fix note in the decisions |
| `prototype/` | the superseded spike. Where the two measurements came from |

`extract.sh` is isolated on purpose: tmux-toolkit refuses transcript parsing
because the vendors document the formats as internal and unstable. When Claude
Code or Pi changes its JSONL, exactly one of `extract.sh` / `extract-pi.sh`
breaks, and nothing else. The prose rules are **not** duplicated: extract-pi.sh
hands its final answer to extract.sh as a one-line Claude-format transcript, so
"same rules" is the same code. The cost of that reuse: changing extract.sh's
rules changes pi's speech too, and extract.sh's own header does not say so.

Two upstream facts shaped the pi dispatch:

- **Tracker detects pi by a `/.pi/sessions/` pattern that the real layout
  (`~/.pi/agent/sessions/`) does not match**, so a pi session can sit in
  `sessions.agent_client` as `claude`. voice.sh checks the session_id shape
  (pi ids are full transcript paths) as a backstop, so dispatch is right either
  way.
- **The pi session dir is derivable from the tracker's `cwd`**
  (`--components-joined-by-dashes--`), and each session file records the cwd it
  launched in, which is the ground-truth scan when derivation fails.

Known gap, accepted: pi answers are markdown-heavy and use `---` horizontal
rules, which extract.sh's rules do not strip, so "dash dash dash" can appear in
speech. Fixing it means changing extract.sh's rules (owned by Claude, kept
unchanged here) or giving pi its own pipeline (drift risk). Left as a decision
for whoever owns extract.sh next.

## Decisions already settled, with the reason

Do not re-open these without new measurements. Each was tried.

1. **No LLM summariser.** `claude -p --safe-mode --model haiku` took 17.1s on a
   real 141-word turn and 5.1s to reply `ok`, so there is a ~5s floor in CLI
   startup alone. The budget was 2s. Lead-sentence extraction ships instead. A
   direct Messages API `curl` would skip the CLI and make an abstract viable
   again, but this machine has no `ANTHROPIC_API_KEY`.
2. **The ~0.5s gap between sentences stays.** Pre-synthesising with `say -o` and
   playing with `afplay` pipelines fine (synthesis is ~6x realtime) but `afplay`
   startup is 0.65-0.85s, *worse* than the 0.5s `say` startup it replaces. Net
   loss plus temp files. Four sentences means ~1.5s of dead air over three gaps.
3. **Two kills, not one.** `stop` TERMs the queue loop, whose trap takes the
   current `say` with it. `skip` TERMs only the `say` child, so the loop's `wait`
   returns and it advances one sentence. Killing the loop alone orphans a `say`
   that keeps talking.
4. **`say` is fed on stdin, not argv.** A sentence starting with a dash would
   otherwise be parsed as a flag.
5. **Wired to `@agent-tracker-on-transition`, not `on-completed`/`on-blocked`.**
   Both of those already push to ntfy.sh on the author's machine. Tracker fires
   `HOOK_ON_<TO>` *and* `HOOK_ON_TRANSITION` for every change, so this adds a
   channel instead of taking one. `install.sh` refuses to overwrite a value that
   is not already ours and prints the chaining command.
6. **`toolkit-ui.sh` on the hook path too.** The library's rule is that a hook
   must not pay for the UI modules, because a Claude hook fires ~12 times a turn.
   A tracker *transition* hook fires once a turn, and the speaker mutex lives in
   `lock.sh`. One entry point, paid once.
7. **`Daniel` is a preference, not an upgrade.** Same 2015 MacinTalk engine as
   Samantha, different accent. A real quality jump needs an Enhanced or Premium
   voice downloaded through System Settings, and those start slower, which may
   force the queue back to one blob plus stop-only. Measure before switching.
8. **The menu dismissal's exit code 1 is suppressed in `lib/menu.sh`, not in
   voice.sh.** `display-menu` returns 1 when dismissed without a selection, and
   with `set -e` that surfaced as "voice.sh returned 1" in the status bar on
   every menu dismissal. The guard belongs at the call site so every toolkit
   consumer gets it, but lib/ is vendored: this is a **local divergence from
   tmux-toolkit 0.2.0** (`tk_menu_show` now ends `|| true`). The next
   `git subtree pull` will conflict or silently revert it — upstream the
   one-liner to tmux-toolkit before pulling, or re-apply it after.

   `f345187` added a **second** divergence in the same file: `tk_menu_cmd` now
   quotes the whole shell command as tmux's single `run-shell` argument, because
   `run-shell 'script' 'arg'` is two arguments and tmux rejects the menu action.
   Both divergences are in tmux-toolkit `main` now (`c21cf0f`, `f54f86d`), but
   consumers subtree from its `dist` branch and `dist` is still the 0.2.0 split
   (`dist^{tree}` != `HEAD:lib` in the toolkit), so there is nothing to pull yet.
   `make release` in tmux-toolkit is the unblock; until then `lib/.checksum`
   here is regenerated from this repo's own lib/, not from 0.2.0.

## Verified, and how

- 43 bats tests, no audio, no network. `say` and `tmux` are stubbed on `PATH`.
- The menu is asserted through `TK_MENU_DRYRUN`, because `display-menu` is a
  client overlay `capture-pane` cannot see.
- Live: the hook fires and returns rc=0 immediately; the detached speaker runs
  Daniel at 200 wpm; `skip` advanced 1 -> 2 -> 3 one press at a time; `stop`
  left zero stray `say` processes and a free lock; a live Pi session (this
  worktree) resolved to the pi extractor even though tracker.db had recorded
  it as `agent_client=claude`.
- `doctor`: say, jq, sqlite3, tmux present, voice installed, tracker db
  readable, wiring present in both the option and tracker's config cache.

## Not verified

- **Whether skip and stop feel right by ear.** The mechanism is proven; the
  ergonomics are not. This needs `prefix + Tab` and `prefix + BSpace` pressed on
  a real turn, and it is the one thing that decides whether the feature is worth
  keeping.
- **Fleet silence with eight other agents live.** `scope=active` is unit-tested
  fail-closed, but never watched under load.
- **The blocked-agent path in anger.** Unit-tested; never triggered by a real
  permission prompt in a background pane.
- **A fresh install on another machine.** `install.sh` has only ever run here,
  where tracker was already present and configured.

## Two traps that already cost real time

- **`grep -c` prints its count *and* exits 1 on zero.** So
  `n=$(grep -c . f || echo 0)` yields `"0\n0"`. Broke four prototype tests and
  was latent in `cmd_status`. Correct form is in `helpers.bash:71`.
- **A stub `tmux` keyed on its last argument silently defeats the config tests.**
  `tk_opt` calls `show-option -gqv <key>`; `tk_opt_bulk` calls `show-options -g`
  with **no key** and greps by prefix. A stub answering `-g` returns nothing,
  every option falls back to its default, and gate tests pass while exercising
  nothing. Two did exactly that. `voice.bats:181` is the canary that catches it.

## Depends on work in other repos

Neither is fixed here, deliberately: another agent owns the toolkit and was
mid-flight. Findings are filed at
`~/Code/tmux-toolkit/docs/NG-report-agent-voice.md` (**uncommitted**, so a
`git add -A` in that repo will sweep it in).

- **NG-1, was blocking.** The toolkit's `dist` branch was stale at 0.1.0, so the
  documented `git subtree add ... dist` silently vendored a library with no
  `toolkit-ui.sh`, and the first symptom was `tk_lock: command not found` from
  inside a hook hours later. Unblocked by running `make dist` locally, which
  rewrote only a local branch ref.
- **NG-3, live.** tmux-agent-tracker's `_load_config_fast` (`tracker.sh:696-701`)
  sources its config cache with **no age check**, so a cache written before the
  option was set keeps `HOOK_ON_TRANSITION=''` forever and the hook silently
  never fires. Worked around in the wrong repo: `install.sh` deletes the cache,
  `doctor` asserts on the cache contents. Both should be deleted once tracker is
  ported onto `tk_config_load`.
- **Pi detection pattern is stale.** tracker.sh's `_detect_agent_client`
  (`tracker.sh:443`) matches `*/.pi/sessions/*`, but pi writes sessions to
  `~/.pi/agent/sessions/`, so pi sessions are recorded as `agent_client=claude`.
  voice.sh works around it by also checking the session_id shape; the tracker
  fix is one pattern change.
- **NG-4, a missing shape.** `tk_lock` is non-blocking by design, with no "steal
  from a live holder", which is what barge-in needs. Composed by hand here:
  `tk_lock_dir`, TERM the holder, `tk_unlock`, `tk_lock`. A `tk_lock_steal` would
  stop the next consumer re-deriving it.

## Next, in the order it should happen

1. Press `prefix + Tab` and `prefix + BSpace` on a real turn and decide whether
   the interrupt feels right. Everything below is wasted if it does not.
2. Watch `scope=active` with the full fleet running, then toggle to `any` and
   confirm newest-wins barge-in kills the previous speaker instead of overlapping.
3. Trigger a real permission prompt in a background pane; confirm the spoken line
   names the right project out of `tracker.db`.
4. When the toolkit lands NG-3, delete the cache workaround from `install.sh` and
   the cache assertion from `doctor`.
5. Re-pull `lib/` when the toolkit publishes a release, i.e. once `make release`
   in tmux-toolkit moves `dist` past the 0.2.0 split:
   `git subtree pull --prefix=lib <toolkit> dist --squash`, then regenerate
   `lib/.checksum` and re-run the suite. Both menu divergences (decision 8) are
   already upstream in toolkit `main`, so a pull from a fresh `dist` should
   absorb them. Verify that, do not assume it.
6. Push the stale `/.pi/sessions/` detection pattern to tmux-agent-tracker
   (see Depends on work in other repos), then the sid-shape backstop in
   `_harness_of` becomes redundant.

## Undone and knowingly so

- The lead-sentence heuristic speaks filler when a turn does not open with its
  conclusion. Observed: "Set @voice-voice to Daniel." and "Done in the plan."
  This is the cost of decision 1 and there is no fix without an LLM.
- Pi answers are markdown-heavy, and `---` horizontal rules survive the
  extractor, so "dash dash dash" can appear mid-summary. Same rules as Claude
  by design; a fix belongs in extract.sh's rule set, which this change does not
  touch.
- No `ARCHITECTURE.md` or `ROADMAP.md`; two siblings have them, this does not
  need them yet.
- Voice cycling is hardcoded to the six non-novelty English voices on a stock
  macOS (`voice.sh:241`). It does not enumerate `say -v '?'`.
