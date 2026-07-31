#!/usr/bin/env bash
# extract-pi.sh <session-dir> [max_sentences]
#
# The final Pi assistant turn, as speakable sentences, one per line.
#
# This is the one file in the plugin that touches
# ~/.pi/agent/sessions/<session>/<session-id>.jsonl, the same isolation
# contract extract.sh has for ~/.claude: pi's session jsonl is internal and
# undocumented, and when the format changes, this file is the only thing that
# breaks.
#
# The prose rules and the sentence split are not copied here. They live in
# extract.sh; this file synthesises a one-line Claude-format transcript
# carrying the final answer and hands it over, so "same rules" means literally
# the same code and the two extractors cannot drift apart. The pi-specific
# knowledge - where sessions live, how a turn is shaped - is all in this file;
# nothing here ever reads ~/.claude.
set -euo pipefail

DIR="${1:?usage: extract-pi.sh <session-dir> [max_sentences]}"
MAX="${2:-4}"

command -v jq >/dev/null 2>&1 || { echo "extract-pi.sh: jq required" >&2; exit 1; }
[[ -d "$DIR" ]] || { echo "extract-pi.sh: no such session dir: $DIR" >&2; exit 1; }

# 1. the latest session file. The filename embeds a UTC timestamp
#    (2026-07-31T05-05-10-034Z_<id>.jsonl), so lexical order is chronological.
#    LC_ALL=C keeps the sort byte-order even under a UTF-8 collation.
f="$(find "$DIR" -maxdepth 1 -name '*.jsonl' -print 2>/dev/null | LC_ALL=C sort | tail -1)"
[[ -n "$f" ]] || { echo "extract-pi.sh: no transcripts in $DIR" >&2; exit 1; }

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 2. the final assistant turn, as one Claude-shaped assistant line.
#
# Pi writes one json object per model step. A user prompt is a message whose
# role is "user" with a text entry; assistant steps carry thinking/toolCall/
# text entries; tool results are role "toolResult" and carry the tool output.
# Everything after the last user prompt that is an assistant text entry is
# collected, and only the LAST one survives: pi narrates out loud before every
# tool call ("Let me check..."), and that running commentary is not the answer.
#
# Tolerated: an alternate shape where message is the content array itself and
# the role sits on the line (role resolves from either place). When no user
# prompt is attributable, the last text entry in the whole file still lands,
# which is the final output either way.
tmp="$(mktemp "${TMPDIR:-/tmp}/tav-pi.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq -rs '
  def msg: .message | if type == "array" then { role: null, content: . } else . end;
  def msg_role: (msg.role // .role) // "";
  def msg_content: msg.content // [];

  def is_user_prompt:
    .type == "message"
    and msg_role == "user"
    and ([ msg_content[]? | select(.type == "text" and ((.text // "") | length > 0)) ] | length > 0);

  ( [ range(0; length) as $i | select(.[$i] | is_user_prompt) | $i ] | last // -1 ) as $u
  | [ .[($u + 1):][]
      | select(.type == "message" and msg_role == "assistant")
      | msg_content[]?
      | select(.type == "text")
      | .text ]
  | last // empty
  | "{\"type\":\"assistant\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":" + (. | @json) + "}]}}"
' "$f" > "$tmp"

# 3. extract.sh owns the prose rules and the sentence split; its exit status
#    is ours (0 with output, 0 empty when there was nothing speakable).
rc=0
"$SCRIPTS_DIR/extract.sh" "$tmp" "$MAX" || rc=$?
exit "$rc"
