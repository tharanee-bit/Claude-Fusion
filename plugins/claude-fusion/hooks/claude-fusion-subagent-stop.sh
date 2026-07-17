#!/usr/bin/env bash
# Canonical claude-fusion-subagent-stop.sh  (Codex SubagentStop hook)
# Review the capped final message from every subagent under a gated parent turn. At most the
# configured number of unique agents are reviewed per parent turn; failures are deliberately
# fail-open. The event's agent_transcript_path is never read or transmitted.
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/claude-fusion-common.sh
. "$SCRIPT_DIR/claude-fusion-common.sh" 2>/dev/null || exit 0
clf_init_common "SUBSTOP"

clf_nested_fusion_active && exit 0
clf_enabled "$SUBAGENT_REVIEW" || { clf_dbg "disabled -> exit"; exit 0; }
clf_setup_claude_runtime || exit 0

MAX_DIFF=12000
MAX_MESSAGE_CHARS=12000
MAX_REVIEW_CHARS=12000

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0
# Deliberately exclude agent_transcript_path from this field list. Claude Fusion never opens it.
FIELDS="$(clf_parse_fields "$INPUT" cwd session_id turn_id stop_hook_active agent_id agent_type last_assistant_message)"
CWD="$(clf_field "$FIELDS" 1)"
SESSION_ID="$(clf_sanitize_session_id "$(clf_field "$FIELDS" 2)")"
TURN_ID="$(clf_sanitize_session_id "$(clf_field "$FIELDS" 3)")"
STOP_ACTIVE="$(clf_field "$FIELDS" 4)"
AGENT_ID="$(clf_sanitize_session_id "$(clf_field "$FIELDS" 5)")"
AGENT_TYPE="$(clf_field "$FIELDS" 6)"
LAST_MESSAGE="$(clf_field "$FIELDS" 7)"
TURN_KEY="$(clf_turn_key "$SESSION_ID" "$TURN_ID")"

[ "$STOP_ACTIVE" = "true" ] && { clf_dbg "stop_hook_active -> exit"; exit 0; }
[ -d "$CWD" ] || CWD="$PWD"
MARKER="$(clf_find_complex_marker "$SESSION_ID" "$TURN_ID")"
[ -n "$MARKER" ] || { clf_dbg "no complex parent marker -> exit"; exit 0; }
[ -n "$TURN_KEY" ] || exit 0

# Keep the cap in Unicode characters, not bytes, then explicitly mark truncation.
LAST_MESSAGE="$(printf '%s' "$LAST_MESSAGE" | MAX_MESSAGE_CHARS="$MAX_MESSAGE_CHARS" "$PY" -c '
import os, sys
text = sys.stdin.read()
limit = int(os.environ.get("MAX_MESSAGE_CHARS", "12000"))
if len(text) > limit:
    text = text[:limit]
    cut = text.rfind("\n")
    if cut > 0: text = text[:cut]
    text += "\n\n[...subagent final message truncated at 12000 characters...]"
sys.stdout.write(text)
' 2>/dev/null)"
[ -n "$LAST_MESSAGE" ] || LAST_MESSAGE="(subagent returned no final assistant message)"

clf_ensure_state_dir || exit 0
if [ -z "$AGENT_ID" ]; then
  AGENT_ID="unknown-$(printf '%s\n%s' "$AGENT_TYPE" "$LAST_MESSAGE" | git hash-object --stdin 2>/dev/null)"
fi
DEDUPE_DIR="$STATE_DIR/$TURN_KEY.subagent-agent-$AGENT_ID"
mkdir "$DEDUPE_DIR" 2>/dev/null || { clf_dbg "duplicate agent event -> exit"; exit 0; }

SLOT=""
_slot=1
while [ "$_slot" -le "$SUBAGENT_REVIEW_LIMIT" ]; do
  _candidate="$STATE_DIR/$TURN_KEY.subagent-slot-$_slot"
  if mkdir "$_candidate" 2>/dev/null; then SLOT="$_slot"; break; fi
  _slot=$((_slot + 1))
done
[ -n "$SLOT" ] || { clf_dbg "subagent review cap reached -> exit"; exit 0; }

BASE="$(cat "$MARKER" 2>/dev/null)"
case "$BASE" in *[!0-9a-f]*) BASE="";; esac
if [ -z "$BASE" ] || ! git -C "$CWD" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  BASE="HEAD"
fi
DIFF_FULL="$(clf_filtered_diff "$CWD" "$BASE" 2>/dev/null)"
if [ -n "$DIFF_FULL" ]; then
  DIFF="$(clf_truncate_bytes "$DIFF_FULL" "$MAX_DIFF" "parent-turn diff")"
else
  DIFF="(no reviewable repository diff yet; review the subagent's final message and reasoning claims)"
fi

if [ "${#CLAUDE_SAFE_ARGS[@]}" -gt 0 ] && ! clf_safe_mode_supported; then
  clf_dbg "claude lacks --safe-mode -> fail open"
  exit 0
fi

CLAUDE_PROMPT="You are Claude acting as an independent reviewer for an OpenAI Codex subagent.
You are running automatically from a synchronous Codex SubagentStop hook, in READ-ONLY mode.
Do not edit files or run mutating commands. Do not inspect credentials, tokens, .env files,
keychains, shell history, or auth files. The transcript is intentionally unavailable.

Review the subagent's final message and any filtered parent-turn diff for SERIOUS problems only:
incorrect claims or implementation, security vulnerabilities, data-loss or concurrency risks, and
broken or missing tests. Research-only subagents still require review for unsupported conclusions.
Ignore style nits. Keep findings concise and actionable.

The VERY FIRST line of a text response MUST be exactly one of:
CLAUDE_REVIEW_VERDICT: PASS
CLAUDE_REVIEW_VERDICT: ISSUES_FOUND

If ISSUES_FOUND, list each issue as:
- <location if known> : <problem> : <minimal fix>

Repository:
$CWD

Agent id: $AGENT_ID
Agent type: ${AGENT_TYPE:-unknown}
Reserved review slot: $SLOT of $SUBAGENT_REVIEW_LIMIT

Subagent final assistant message:
$LAST_MESSAGE

Filtered parent-turn diff:
$DIFF"

clf_build_claude_args
CLF_CONTRACT_TYPE=review
CLF_JSON_SCHEMA='{"type":"object","additionalProperties":false,"required":["verdict","findings"],"properties":{"verdict":{"type":"string","enum":["PASS","ISSUES_FOUND"]},"findings":{"type":"array","maxItems":12,"items":{"type":"string"}}}}'
CLF_KEEP_SESSION=0
CLF_RESUME_ID=""
clf_dbg "running subagent review agent=$AGENT_ID slot=$SLOT"
clf_run_claude_contract
[ "$CLF_RC" -eq 0 ] && [ -n "$CLF_OUTPUT" ] || { clf_dbg "review failed -> fail open"; exit 0; }

if [ "$CLF_RESULT_MODE" = "structured" ]; then
  REVIEW="$(printf '%s' "$CLF_OUTPUT" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
print("CLAUDE_REVIEW_VERDICT: " + d["verdict"])
for item in d.get("findings", []): print("- " + item)
' 2>/dev/null)"
else
  REVIEW="$CLF_OUTPUT"
fi
VERDICT_LINE="$(clf_first_nonempty_line "$REVIEW")"
printf '%s' "$VERDICT_LINE" | grep -qiE 'CLAUDE_REVIEW_VERDICT:[[:space:]]*ISSUES_FOUND' || {
  clf_dbg "subagent verdict PASS/none"
  exit 0
}

REVIEW="$(clf_truncate_bytes "$REVIEW" 100000 "claude subagent review")" MAX_CHARS="$MAX_REVIEW_CHARS" "$PY" <<'PY'
import json, os
review = os.environ.get("REVIEW", "")
limit = int(os.environ.get("MAX_CHARS", "12000"))
if len(review) > limit:
    review = review[:limit]
    cut = review.rfind("\n")
    if cut > 0: review = review[:cut]
    review += "\n\n[...review truncated at 12000 characters...]"
reason = ("AUTOMATIC CLAUDE FUSION - SUBAGENT REVIEW:\n"
          "Claude found a serious issue in this subagent's result. Correct it before the subagent "
          "finishes, or explicitly justify why the finding is not applicable.\n\n" + review)
print(json.dumps({"decision": "block", "reason": reason}))
PY
clf_dbg "blocked subagent with ISSUES_FOUND"
exit 0
