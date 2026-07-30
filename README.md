# tmux-agent-voice

Your agents tell you what they did, out loud, and you can cut them off mid-word.

A finished turn becomes four spoken sentences. `prefix + Tab` abandons the current
sentence and jumps to the next, `prefix + BSpace` silences everything. Only the
pane you are looking at speaks, so a fleet of nine agents does not talk over
itself. A blocked agent in a pane you are *not* looking at says so.

macOS only: the engine is `say(1)`. Requires
[tmux-agent-tracker](https://github.com/KakkoiDev/tmux-agent-tracker), which owns
the session-to-pane mapping this reads, plus `jq` and `sqlite3`.

## Install

```sh
git clone https://github.com/KakkoiDev/tmux-agent-voice ~/Code/tmux-agent-voice
cd ~/Code/tmux-agent-voice
./install.sh          # symlinks the CLI, wires the tracker hook, runs doctor
```

Then add to `~/.tmux.conf` and reload with `prefix + r`:

```tmux
run '~/Code/tmux-agent-voice/agent-voice.tmux'
```

`./uninstall.sh` reverses all of it. Try it without waiting for a turn to finish:
`tmux-agent-voice demo`.

`~/.claude/settings.json` is not touched. Wiring goes through
tmux-agent-tracker's `@agent-tracker-on-transition`, which tracker already fires
for every status change with `from to sid project summary`. Tracker owns the
session-to-pane and session-to-project mapping, so nothing here parses a harness
payload.

`on-transition` specifically, and not `on-completed`/`on-blocked`: on this machine
both of those already push to ntfy.sh. Tracker fires `HOOK_ON_<TO>` *and*
`HOOK_ON_TRANSITION` for every change, so this adds a channel rather than taking
one. `install.sh` refuses to overwrite an `on-transition` that is not already ours
and prints the chaining command instead.

## Keys

| | |
|---|---|
| `prefix + Tab` | skip this sentence, continue with the next (repeatable, no re-prefix) |
| `prefix + BSpace` | stop, mid-word |
| `prefix + V` | menu: toggle speaking, scope, alerts; cycle voice and rate |

All three were verified unbound in tmux 3.5a defaults and in the local config.

## Config

tmux options, namespace `@agent-voice-`:

| Option | Default | |
|---|---|---|
| `@agent-voice-voice` | `Daniel` | any name from `say -v '?'` |
| `@agent-voice-rate` | `200` | words per minute |
| `@agent-voice-enabled` | `on` | |
| `@agent-voice-scope` | `active` | `active` = focused pane only, `any` = every agent |
| `@agent-voice-sentences` | `4` | how many sentences to speak |
| `@agent-voice-notify` | `on` | announce blocked agents |
| `@agent-voice-key`, `-key-stop`, `-key-skip` | `V`, `BSpace`, `Tab` | |

`tmux-agent-voice doctor` checks all of it, including whether tracker's cache
actually carries the hook, which is not the same question as whether the option is
set. See NG-3 below.

## Why it works the way it does

**Two kills, not one.** `stop` sends TERM to the queue loop, whose trap takes the
current `say` down with it. `skip` sends TERM only to the `say` child, so the
loop's `wait` returns and it advances one sentence. Killing the loop alone would
orphan a `say` that keeps talking.

**`say` is fed through stdin, not argv.** A sentence beginning with a dash would
otherwise be parsed as a flag.

**The speaker mutex is `tk_lock`, and its pid file *is* the speaker pid.** No
separate `speaker.pid` to go stale.

**The hook detaches immediately.** A transition hook that waits holds the turn
open for the entire length of the audio.

## Two measurements that shaped this

**There is no LLM in the path, because the obvious one cost 17 seconds.**
`claude -p --safe-mode --model haiku` summarising a real 141-word turn took 17.1s
wall clock, and 5.1s just to reply `ok`, so there is a 5-second floor in CLI
startup before any tokens. The budget was 2s. `extract.sh` does lead-sentence
extraction instead: zero latency, no network. If an `ANTHROPIC_API_KEY` ever
exists here, a direct Messages API `curl` skips the CLI and the abstract becomes
viable again. The `CLAUDE_VOICE_SPEAKING` guard stays regardless, because any
future summariser is another Claude Code that fires this same transition.

**Sentences cost ~0.5s of `say` startup each, and the obvious fix is worse.**
Measured by subtracting audio duration from wall clock across 1, 10 and 20-word
utterances. Pre-synthesising the next sentence with `say -o` while the current one
plays is 6x faster than realtime, so it pipelines fine, but `afplay` startup is
0.65 to 0.85s: *worse* than the `say` startup it would replace, plus temp files.
Not done. Four sentences means about 1.5s of dead air across three gaps. Accepted.

## Extraction rules

Every rule is here because the unfiltered version is unlistenable.

- Only the final turn: everything after the last real user prompt. `tool_result`
  entries are also `type: user` and are excluded.
- `isSidechain: true` excluded, or the voice reads subagent output.
- Dropped: fenced code, table rows, headings. URLs become "a link". Absolute paths
  collapse to their basename.
- A leading `[marker]` token is dropped, or the voice reads harness noise aloud.
- `_` becomes a space, not nothing, so `en_US` speaks as "en US" and not "enUS".
- Sentence splitting does not break on `3.5a`, on `24.1`, or after `e.g.`

The last two were found by running the extractor against a real transcript, not by
reading it. Both have regression tests.

`scripts/extract.sh` is the only file that touches `~/.claude/**/*.jsonl`, and it
honours `CLAUDE_CONFIG_DIR`. It is isolated because tmux-toolkit refuses that
responsibility on purpose: the vendor documents the format as internal and
unstable. When it changes, that one file is what breaks.

## Tests

```sh
bats tests/               # 24 tests, no audio, no network
/bin/bash "$(command -v bats)" tests/      # and again under bash 3.2
shellcheck -S warning -x scripts/*.sh install.sh uninstall.sh agent-voice.tmux bin/*
```

`say` and `tmux` are stubbed on `PATH`; the menu is asserted through
`TK_MENU_DRYRUN` because `display-menu` is a client overlay that `capture-pane`
cannot see.

Two things in here exist because they already caught real failures:

- **No fixed sleeps.** `wait_says`, `wait_file` and `wait_grep` poll. `voice.sh`
  sources twelve library files and does one cold `tk_config_load` fork before it
  speaks, and the hook path pays that twice because it re-execs detached. Three
  tests were flaky on a 1-second margin.
- **A canary that a set option reaches the code.** `tk_opt` calls
  `show-option -gqv <key>`; `tk_opt_bulk` calls `show-options -g` with *no key*.
  A stub keyed on the last argument answers `-g`, returns nothing, and every
  option falls back to its default, so gate tests pass while exercising nothing.
  Two of mine did exactly that before this test existed.

`prototype/` is the three-file spike that produced both measurements above. It is
superseded, not installed, and kept only because that is where they were taken.

`HANDOFF.md` has the rest: what is verified, what is not, and the two upstream
bugs this works around.

## Toolkit dependency

`lib/` is tmux-toolkit 0.2.0, vendored by `git subtree`. Do not edit it in place;
`make sync-check` in the toolkit exists to catch that.

Findings sent upstream live in `tmux-toolkit/docs/NG-report-agent-voice.md`. The
one that affects a fresh install: the `dist` branch was stale at 0.1.0, so the
documented `git subtree add ... dist` silently vendored a library with no
`toolkit-ui.sh`. Regenerated with `make dist`.

NG-3 is the one to know about while using this: tracker's `_load_config_fast`
(`tracker.sh:697-701`) sources its config cache with no age check, so a cache
written before the option was set keeps `HOOK_ON_TRANSITION=''` indefinitely and
the hook silently never fires. `install.sh` deletes the cache and `doctor` asserts
on the cache contents, both of which are workarounds in the wrong repo.
