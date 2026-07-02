#!/usr/bin/env bash
# claude-fusion-stop.sh  (Codex Stop hook)
# When the finished task was gated-complex (marker from the UserPromptSubmit hook) AND there are
# working-tree changes since the prompt-time HEAD recorded in that marker, run Claude READ-ONLY over
# the filtered diff. If Claude returns ISSUES_FOUND, block ONCE (decision:block) with the review.
# For Codex's Stop event, decision:block does not reject the turn -- it makes Codex continue, using
# `reason` as a new prompt. Loop-safe; never errors out.
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/claude-fusion-common.sh
. "$SCRIPT_DIR/claude-fusion-common.sh" 2>/dev/null || exit 0
clf_init_common "STOP"

# Recursion guard (see the common helper).
clf_nested_fusion_active && exit 0

clf_setup_claude_runtime || exit 0

MAX_DIFF=20000
MAX_CHARS=12000

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0
FIELDS="$(clf_parse_fields "$INPUT" cwd session_id stop_hook_active)"
CWD="$(clf_field "$FIELDS" 1)"
SESSION_ID="$(clf_sanitize_session_id "$(clf_field "$FIELDS" 2)")"
STOP_ACTIVE="$(clf_field "$FIELDS" 3)"

# loop guard: we're already inside a continuation we forced -> don't review again
[ "$STOP_ACTIVE" = "true" ] && { clf_dbg "stop_hook_active -> exit"; exit 0; }
[ -d "$CWD" ] || CWD="$PWD"

MARKER="$STATE_DIR/$SESSION_ID.complex"
[ -n "$SESSION_ID" ] && [ -f "$MARKER" ] || { clf_dbg "no complex marker -> exit"; exit 0; }
REVIEWED_FILE="$STATE_DIR/$SESSION_ID.reviewed"
FAILED_FILE="$STATE_DIR/$SESSION_ID.failed-review"

# Diff against the prompt-time HEAD recorded in the marker, not the current one, so commits made
# during the turn stay in the review surface. Empty/unresolvable marker content (pre-upgrade format,
# non-git cwd at prompt time, rebase, gc) falls back to HEAD: fail-open toward reviewing.
BASE="$(cat "$MARKER" 2>/dev/null)"
case "$BASE" in *[!0-9a-f]*) BASE="";; esac
if [ -z "$BASE" ] || ! git -C "$CWD" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  [ -n "$BASE" ] && clf_dbg "stored base sha unresolvable -> falling back to HEAD"
  BASE="HEAD"
fi

DIFF_FULL="$(clf_filtered_diff "$CWD" "$BASE" 2>/dev/null)"
[ -n "$DIFF_FULL" ] || { clf_dbg "empty diff -> exit"; rm -f "$MARKER" 2>/dev/null; exit 0; }
DIFF="$(clf_truncate_bytes "$DIFF_FULL" "$MAX_DIFF" "diff")"
CHANGED="$(clf_truncate_bytes "$(clf_filtered_status "$CWD")" 3000 "changed files")"
# NOTE: the marker is deleted only on a DEFINITIVE outcome (PASS, a delivered ISSUES_FOUND block, or
# an unchanged already-reviewed diff), not here. A transient failure leaves it for the next Stop.

# Hash the FULL filtered diff, not the truncated payload: otherwise any change past the truncation
# point hashes identically and a genuinely new diff would be skipped as already reviewed.
DIFF_HASH="$(printf '%s' "$DIFF_FULL" | git hash-object --stdin 2>/dev/null)"
LAST_REVIEWED="$(cat "$REVIEWED_FILE" 2>/dev/null)"
if [ -n "$DIFF_HASH" ] && [ "$LAST_REVIEWED" = "$DIFF_HASH" ]; then
  clf_dbg "diff already reviewed -> exit"
  rm -f "$MARKER" 2>/dev/null
  exit 0
fi

retry_limit() {
  clf_positive_int "${CLAUDE_FUSION_STOP_RETRY_LIMIT:-2}" 2
}

retry_exhausted() {
  [ -f "$FAILED_FILE" ] || return 1
  read -r _hash _count <"$FAILED_FILE" 2>/dev/null
  [ "$_hash" = "$DIFF_HASH" ] || return 1
  [ "${_count:-0}" -ge "$(retry_limit)" ]
}

record_review_failure() {
  clf_ensure_state_dir || return 0
  _old_hash=""
  _old_count=0
  [ -f "$FAILED_FILE" ] && read -r _old_hash _old_count <"$FAILED_FILE" 2>/dev/null
  if [ "$_old_hash" = "$DIFF_HASH" ]; then
    _new_count=$(( ${_old_count:-0} + 1 ))
  else
    _new_count=1
  fi
  printf '%s %s\n' "$DIFF_HASH" "$_new_count" >"$FAILED_FILE" 2>/dev/null
  clf_dbg "recorded review failure count=$_new_count hash=$DIFF_HASH"
}

clear_review_failure() {
  rm -f "$FAILED_FILE" 2>/dev/null
}

store_reviewed() {
  [ -n "$DIFF_HASH" ] || return 0
  clf_ensure_state_dir && printf '%s\n' "$DIFF_HASH" >"$REVIEWED_FILE" 2>/dev/null
}

retry_exhausted && { clf_dbg "review retry cap reached for unchanged diff"; exit 0; }

if [ "${#CLAUDE_SAFE_ARGS[@]}" -gt 0 ] && ! clf_safe_mode_supported; then
  clf_dbg "claude lacks --safe-mode -> exit (marker kept; update Claude Code or set CLAUDE_FUSION_SAFE_MODE=0)"
  exit 0
fi

WF_NOTE=""
if [ "$DEPTH" = "workflow" ] && [ "$CUSTOM_CLAUDE_CONTEXT" -eq 1 ]; then
  WF_NOTE="
You may run a READ-ONLY multi-agent adversarial review (dynamic workflows / parallel subagents) for
deeper coverage. Do not edit files or run mutating commands."
elif [ "$DEPTH" = "workflow" ]; then
  WF_NOTE="
Run a thorough READ-ONLY review rather than a single quick pass. Claude Fusion is running you in
--safe-mode, so do not rely on user/project Claude customizations, skills, plugins, workflows,
memory, MCP servers, or custom agents."
fi

CLAUDE_PREFIX=""
[ "$DEPTH" = "workflow" ] && [ "$CUSTOM_CLAUDE_CONTEXT" -eq 1 ] && CLAUDE_PREFIX="ultracode: "
CLAUDE_PROMPT="${CLAUDE_PREFIX}You are Claude acting as an independent code reviewer for the OpenAI Codex agent.
You are running automatically from a Codex Stop hook, in READ-ONLY mode.
Do not edit files. Do not run destructive commands.
Do not inspect credentials, tokens, .env files, keychains, shell history, or auth files.$WF_NOTE

Review the git diff below for SERIOUS problems only: correctness bugs, security
vulnerabilities, data-loss risks, concurrency/race issues, and broken or missing tests.
Ignore pure style/formatting nits.

The VERY FIRST line of your response MUST be exactly one of:
CLAUDE_REVIEW_VERDICT: PASS
CLAUDE_REVIEW_VERDICT: ISSUES_FOUND

If ISSUES_FOUND, list each serious issue (most important first) as:
- <file:line> : <problem> : <minimal fix>
Keep it under 800 words.

Repository:
$CWD

Changed files:
$CHANGED

Diff:
$DIFF"

clf_build_claude_args
clf_dbg "running claude review (model=$CLAUDE_MODEL, effort=$CLAUDE_EFFORT, depth=$DEPTH)"
clf_run_claude_with_retry
REVIEW="$CLF_OUTPUT"
RC="$CLF_RC"
# On a transient failure, KEEP the marker so the next genuine Stop retries the review; the bounded
# failure counter stops an unchanged diff from retrying forever.
[ "$RC" -eq 0 ] || { record_review_failure; clf_dbg "claude rc!=0 -> exit (marker kept for retry)"; exit 0; }
[ -n "$REVIEW" ] || { record_review_failure; clf_dbg "empty review -> exit (marker kept)"; exit 0; }

# Only block when Claude explicitly flags issues. The verdict is the FIRST non-empty line, so check
# only that -- this also stops injected diff/prompt content from forging the control token.
VERDICT_LINE="$(clf_first_nonempty_line "$REVIEW")"
if ! printf '%s' "$VERDICT_LINE" | grep -qiE 'CLAUDE_REVIEW_VERDICT:[[:space:]]*ISSUES_FOUND'; then
  # Definitive PASS: consume the marker (review once) and remember the reviewed payload hash so an
  # unchanged diff is not re-reviewed by a later gated prompt.
  rm -f "$MARKER" 2>/dev/null
  store_reviewed
  clear_review_failure
  clf_dbg "verdict PASS/none -> exit"
  exit 0
fi

emit_block() {
  # Shell-side cap BEFORE the env handoff: a single env string over ~128KiB fails execve (E2BIG),
  # the python truncation would never run, and a review that found issues would be silently lost.
  REVIEW="$(clf_truncate_bytes "$1" 100000 "claude review")" MAX_CHARS="$MAX_CHARS" "$PY" <<'PY'
import os, json
r = os.environ.get("REVIEW", "")
try: m = int(os.environ.get("MAX_CHARS", "12000"))
except Exception: m = 12000
if len(r) > m:
    r = r[:m]
    cut = r.rfind("\n")
    if cut > 0:
        r = r[:cut]
    r += "\n\n[...review truncated at " + str(m) + " chars...]"
reason = ("AUTOMATIC CLAUDE FUSION - POST-DIFF REVIEW:\n"
          "Claude independently reviewed your git diff and flagged potential issues. Address the "
          "serious problems (correctness, security, data-loss, concurrency, broken tests) before "
          "finalizing, or explicitly justify why each is not a real issue. You remain the final judge.\n\n" + r)
print(json.dumps({"decision": "block", "reason": reason}))
PY
}

# Consume the marker and store the reviewed hash only AFTER the block is actually delivered; a
# failed emission keeps the marker (and records a bounded failure) so the finding is not lost.
BLOCK_JSON="$(emit_block "$REVIEW")"
EMIT_RC=$?
[ "$EMIT_RC" -eq 0 ] && [ -n "$BLOCK_JSON" ] || { record_review_failure; clf_dbg "block json emit failed (marker kept)"; exit 0; }
printf '%s\n' "$BLOCK_JSON" || { record_review_failure; clf_dbg "block json delivery failed (marker kept)"; exit 0; }
rm -f "$MARKER" 2>/dev/null
store_reviewed
clear_review_failure
clf_dbg "blocked with ISSUES_FOUND"
exit 0
