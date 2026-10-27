#!/usr/bin/env bash
# Stop hook: anexa a última resposta do Claude em docs/respostas/AAAA-MM-DD.md
set -euo pipefail

input=$(cat)
dir="${CLAUDE_PROJECT_DIR:-$(pwd)}/docs/respostas"

msg=$(jq -r '.last_assistant_message // empty' <<<"$input")
if [ -z "$msg" ]; then
  transcript=$(jq -r '.transcript_path // empty' <<<"$input")
  [ -f "$transcript" ] || exit 0
  msg=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last // empty' "$transcript")
fi
[ -n "$msg" ] || exit 0

mkdir -p "$dir"
printf '## %s\n\n%s\n\n---\n\n' "$(date '+%H:%M:%S')" "$msg" >> "$dir/$(date +%F).md"
