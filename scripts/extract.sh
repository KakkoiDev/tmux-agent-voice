#!/usr/bin/env bash
# extract.sh <transcript.jsonl> [max_sentences]
#
# The final assistant turn, as speakable sentences, one per line.
#
# This is the one file in the plugin that touches ~/.claude/**/*.jsonl. It is
# isolated here because tmux-toolkit refuses that responsibility on purpose: the
# vendor documents the format as internal and unstable. When it changes, this
# file is the only thing that breaks.
set -euo pipefail

TRANSCRIPT="${1:?usage: extract.sh <transcript.jsonl> [max_sentences]}"
MAX="${2:-4}"

command -v jq >/dev/null 2>&1 || { echo "extract.sh: jq required" >&2; exit 1; }
[[ -r "$TRANSCRIPT" ]] || { echo "extract.sh: cannot read $TRANSCRIPT" >&2; exit 1; }

# ── 1. the final assistant turn ───────────────────────────────────────
#
# Everything after the last real user prompt. "Real" excludes tool_result
# entries, which are also type=="user", and excludes sidechain entries, which
# are subagent traffic living in the same file.
raw=$(jq -rs '
  def is_user_prompt:
    .type == "user"
    and (.isSidechain != true)
    and (
      (.message.content | type) == "string"
      or ([ .message.content[]? | select(.type == "text") ] | length > 0)
    );

  ( [ range(0; length) as $i | select(.[$i] | is_user_prompt) | $i ] | last // -1 ) as $u
  | [ .[($u + 1):][]
      | select(.type == "assistant" and (.isSidechain != true))
      | .message.content[]?
      | select(.type == "text")
      | .text ]
  | join("\n\n")
' "$TRANSCRIPT")

[[ -n "${raw//[[:space:]]/}" ]] || exit 0

# ── 2. strip to prose ─────────────────────────────────────────────────
#
# Each rule is here because the unfiltered version is unlistenable, not for
# tidiness. Order matters: fences go before anything that looks inside a line,
# and the leading-marker rule runs before underscores are touched.
prose=$(printf '%s\n' "$raw" | awk '
  /^[[:space:]]*```/ { fence = !fence; next }   # fenced code
  fence              { next }
  /^[[:space:]]*\|/  { next }                   # table rows
  /^[[:space:]]*#/   { next }                   # headings
  { print }
' | sed -E \
  -e 's/^\[[A-Za-z0-9_-]+\][[:space:]]*//' \
  -e 's#https?://[^[:space:]]+#a link#g' \
  -e 's#`([^`]*)`#\1#g' \
  -e 's#/([A-Za-z0-9._-]+/)+([A-Za-z0-9._-]+)#\2#g' \
  -e 's/\*\*([^*]*)\*\*/\1/g' \
  -e 's/[*~]+//g' \
  -e 's/_/ /g' \
  -e 's/^[[:space:]]*[-+][[:space:]]+//' \
  -e 's/^[[:space:]]*[0-9]+\.[[:space:]]+//' \
  -e 's/[[:space:]]+/ /g' \
  -e 's/^ //; s/ $//' \
  | grep -v '^$' || true)

[[ -n "${prose//[[:space:]]/}" ]] || exit 0

# ── 3. split into sentences ───────────────────────────────────────────
#
# Splits on . ! ? followed by whitespace. Two guards: a period between digits
# (3.5a, 24.1) and a known abbreviation do not end a sentence.
printf '%s\n' "$prose" | awk -v max="$MAX" '
  { buf = (buf == "" ? $0 : buf " " $0) }
  END {
    n = length(buf)
    out = ""
    count = 0
    for (i = 1; i <= n; i++) {
      c = substr(buf, i, 1)
      out = out c
      if (c != "." && c != "!" && c != "?") continue

      nxt = substr(buf, i + 1, 1)
      if (nxt != "" && nxt != " ") continue          # 3.5a, e.g., end-of-word
      prv = substr(buf, i - 1, 1)
      if (prv ~ /[0-9]/) continue                    # 24.1 GB
      tail = tolower(substr(out, length(out) - 4))
      if (tail ~ /(e\.g|i\.e|vs|etc|no)\.$/) continue

      gsub(/^ +| +$/, "", out)
      if (out != "" && out != ".") { print out; count++ }
      out = ""
      if (count >= max) exit
      i++                                            # consume the space
    }
    gsub(/^ +| +$/, "", out)
    if (count < max && out != "") print out
  }
'
