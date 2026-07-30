# prototype, superseded, kept for the numbers

Not the plugin. This is the three-file spike that came first, kept because it is
where the two measurements in the top-level README were taken, and because it is
the only place the two killed designs are written down. Nothing installs it,
nothing runs it in CI, and `speak.sh` predates the toolkit so it uses raw
`tmux show-option` and its own pidfiles. The plugin is `../scripts/`.

Prototype for spoken Claude Code turn-endings with mid-sentence interrupt.
Three files, no dependencies beyond `jq` and macOS `say`. Built to answer one
question before the real plugin gets written: does the mechanism work.

It works. Two design decisions from the approved plan did not survive contact
with measurement, both recorded below.

## Try it

```sh
./test.sh                 # 33 assertions, no audio, no network
./speak.sh demo           # four sentences out loud
./speak.sh skip           # from another pane: abandon this sentence
./speak.sh stop           # silence, mid-word
./speak.sh status         # what is speaking and where it got to
./extract.sh ~/.claude/projects/<slug>/<session>.jsonl 4
```

Not wired into `~/.claude/settings.json` on purpose. When you want it live, add
one `Stop` entry:

```json
{ "matcher": "", "hooks": [ { "type": "command",
  "command": "~/Chat/talking-agents/speak.sh hook" } ] }
```

Config, read from tmux options, env var fallback in brackets:

| Option | Default | |
|---|---|---|
| `@voice-voice` | `Daniel` | `TA_VOICE` |
| `@voice-rate` | `200` | `TA_RATE` |
| `@voice-enabled` | `on` | `TA_ENABLED` |
| `@voice-scope` | `active` | `TA_SCOPE` |
| `@voice-sentences` | `4` | `TA_SENTENCES` |

## What measurement changed

**1. The Haiku abstract is cut. It was 17 seconds.**

The plan's step-1 gate was "above roughly 2 seconds and the abstract stops
feeling live". Measured on a real 141-word turn:

| | wall clock |
|---|---|
| `claude -p --safe-mode --model haiku` summarising a real turn | 17.1s |
| `claude -p --safe-mode --model haiku` replying `ok` | 5.1s |

So there is a 5-second floor in CLI startup alone, before any tokens. Ten times
the budget. `extract.sh` now does the plan's own documented fallback instead:
lead-sentence extraction, zero latency, no network, no LLM.

Worth knowing for later: `--safe-mode` disables hooks, MCP, CLAUDE.md, skills
and output styles in one flag. That is a better recursion guard than the
`CLAUDE_VOICE_SPEAKING` env check, and it removes the MCP startup cost. If an
`ANTHROPIC_API_KEY` ever exists here, a direct `curl` to the Messages API skips
the CLI entirely and the abstract becomes viable again. The env guard stays in
`speak.sh` regardless, because it costs one line.

**2. The inter-sentence gap is ~0.5s, not the ~100ms the plan claimed.**

`say -v Daniel` costs about 0.5s of startup per invocation, measured by
subtracting audio duration from wall clock across 1, 10 and 20-word utterances.
With a 4-sentence cap that is roughly 1.5s of dead air spread over three gaps.

The obvious fix does not work. Pre-synthesising the next sentence with
`say -o file.aiff` while the current one plays, then playing with `afplay`:

| | overhead |
|---|---|
| `say` startup | ~0.5s |
| `afplay` startup | ~0.65 to 0.85s |
| `say -o` synthesis, 4s of audio | 0.63s, so ~6x faster than realtime |

Synthesis is cheap enough to pipeline, but `afplay` startup is *worse* than the
`say` startup it was meant to replace. Net loss, plus temp files. Not done.
The 0.5s gap is accepted.

## Design

```
Stop hook -> speak.sh hook            (stdin: {"transcript_path": ...})
  guard  CLAUDE_VOICE_SPEAKING set        -> exit 0   (recursion)
  guard  @voice-enabled off               -> exit 0
  guard  scope=active, TMUX_PANE inactive -> exit 0   (8 other agents stay mute)
  extract.sh -> queue.txt, one sentence per line
  stop any current speaker                           (newest turn wins)
  nohup speak.sh speak queue.txt &, exit 0           (never block the turn)

speak loop:  for each sentence
               printf | say -f - &   ; child pid -> child.pid
               wait child                          (non-zero means skip killed it)

stop:  TERM the loop  -> trap kills the child, both pidfiles removed
skip:  TERM the child -> loop's wait returns, loop advances one sentence
```

Two kills, not one, is the whole trick. Killing the loop alone orphans a `say`
that keeps talking; killing the child alone is exactly skip-ahead.

`say` is fed through stdin rather than argv so a sentence beginning with a dash
is not parsed as a flag.

## Extraction rules

Each rule exists because the unfiltered version is unlistenable.

- Only the final turn: everything after the last real user prompt. `tool_result`
  entries are also `type: user` and are excluded.
- `isSidechain: true` excluded, or the voice reads subagent output.
- Dropped: fenced code blocks, table rows, headings, URLs (become "a link").
- Absolute paths collapse to their basename.
- A leading `[marker]` token is dropped, or the voice reads harness noise aloud.
- `_` becomes a space rather than being deleted, so `en_US` speaks as "en US"
  instead of "enUS". Both of these were found by running the extractor against
  a real transcript, not by inspection; both have regression tests.
- Sentence splitting will not break on `3.5a`, on `24.1`, or after `e.g.`.

## Verified, and not

Verified: 33 assertions green, including all four hook guards refusing to speak,
skip advancing exactly one sentence while the loop survives, stop leaving no
process and no stale pidfile, and extraction against both a synthetic fixture
and a real transcript. Audio confirmed audible with Daniel.

Not verified: whether skip and stop *feel* right by ear, which needs
`./speak.sh demo`. Whether only the focused pane speaks with the other eight
agents live. The `Notification` path for blocked agents, which is not built.

## Deliberately absent

No tmux-toolkit vendoring, no menu, no key bindings, no notification hook. Those
wait for `toolkit-ui.sh`, since the pieces they need (`menu.sh`, `lock.sh`) are
the ones the toolkit documents but has not built. `speak.sh` uses plain
`tmux show-option` where it will later use `tk_opt`, and its own pidfiles where
it will later use `tk_lock_*`.
