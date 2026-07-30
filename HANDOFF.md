# Handoff

Written for whoever picks this up next, including a future me with no memory of
it. Read this before touching anything; it is the only place the dead ends are
written down, and two of them measured worse than the thing they replaced.

State: **working and installed on the author's machine.** 24 bats tests green
(also under bash 3.2), shellcheck clean, `doctor` all ok, audio verified by ear.

## What it is, in one paragraph

A tmux plugin that speaks the last four sentences of a finished Claude Code turn
through macOS `say`, in the voice `Daniel`, at 200 wpm, and only for the pane you
are looking at. `prefix + Tab` abandons the current sentence, `prefix + BSpace`
silences everything mid-word, `prefix + V` opens a `display-menu` of toggles. A
blocked agent in a pane you are *not* looking at announces itself. No LLM in the
path. `~/.claude/settings.json` is never touched.

## Map

| Path | What it owns |
|---|---|
| `scripts/voice.sh` | everything: dispatch, guards, queue loop, menu, doctor |
| `scripts/extract.sh` | the **only** file that reads `~/.claude/**/*.jsonl` |
| `agent-voice.tmux` | TPM entry, three key bindings |
| `install.sh` / `uninstall.sh` | CLI symlink plus tracker wiring, and its reverse |
| `tests/voice.bats` | 24 tests: 9 extraction, 7 gates, 4 interrupt, 4 menu |
| `tests/helpers.bash` | stub `say`, stub `tmux`, polling waiters |
| `lib/` | tmux-toolkit 0.2.0, vendored by `git subtree`. **Do not edit in place.** |
| `prototype/` | the superseded spike. Where the two measurements came from |

`extract.sh` is isolated on purpose: tmux-toolkit refuses transcript parsing
because the vendor documents the format as internal and unstable. When Claude
Code changes its JSONL, that one file is what breaks, and nothing else.

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

## Verified, and how

- 24 bats tests, no audio, no network. `say` and `tmux` are stubbed on `PATH`.
- The menu is asserted through `TK_MENU_DRYRUN`, because `display-menu` is a
  client overlay `capture-pane` cannot see.
- Live: the hook fires and returns rc=0 immediately; the detached speaker runs
  Daniel at 200 wpm; `skip` advanced 1 -> 2 -> 3 one press at a time; `stop`
  left zero stray `say` processes and a free lock.
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
5. Re-pull `lib/` when the toolkit tags a release:
   `git subtree pull --prefix=lib <toolkit> dist --squash`, then re-run the suite.

## Undone and knowingly so

- The lead-sentence heuristic speaks filler when a turn does not open with its
  conclusion. Observed: "Set @voice-voice to Daniel." and "Done in the plan."
  This is the cost of decision 1 and there is no fix without an LLM.
- No `ARCHITECTURE.md` or `ROADMAP.md`; two siblings have them, this does not
  need them yet.
- Voice cycling is hardcoded to the six non-novelty English voices on a stock
  macOS (`voice.sh:241`). It does not enumerate `say -v '?'`.
