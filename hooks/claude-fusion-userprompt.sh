#!/usr/bin/env bash
# claude-fusion-userprompt.sh  (Codex UserPromptSubmit hook)
# Auto-consult Claude Code (READ-ONLY) as an independent peer on non-trivial coding prompts and
# inject its analysis into Codex's context. Mirror image of Codex Fusion, reversed: here Codex is
# the primary agent and Claude is the advisor.
# GUARANTEE: never blocks Codex on the no-action path -- always exits 0. Escape hatch: [no-claude].
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/claude-fusion-common.sh
. "$SCRIPT_DIR/claude-fusion-common.sh" 2>/dev/null || exit 0
clf_init_common "UPS"

# Recursion guard: if we are already inside a Fusion -> peer call (env inherited through the process
# tree), do nothing. This breaks any claude<->codex hook loop when both Fusions are installed.
clf_nested_fusion_active && exit 0

clf_setup_claude_runtime || exit 0

MAX_CHARS=12000

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0
FIELDS="$(clf_parse_fields "$INPUT" prompt cwd session_id)"
PROMPT="$(clf_field "$FIELDS" 1)"
CWD="$(clf_field "$FIELDS" 2)"
SESSION_ID="$(clf_sanitize_session_id "$(clf_field "$FIELDS" 3)")"
[ -n "$PROMPT" ] || exit 0
[ -d "$CWD" ] || CWD="$PWD"

# Outside a git repo the Stop-hook diff review can never run; that must be visible, not silent
# (mirror of Codex Fusion's one-time notice). Emitted inside hookSpecificOutput.additionalContext --
# the only injection channel verified against Codex; switch to a systemMessage only after manually
# verifying Codex honors that key. Keyed on the bare session id (this side's state-file convention);
# without a session id there is no way to warn once, so stay silent rather than warn every prompt.
NOGIT_MARKER="$STATE_DIR/$SESSION_ID.nogit-warned"
NONGIT_WARNING=""
if [ -n "$SESSION_ID" ] && [ ! -f "$NOGIT_MARKER" ] && ! git -C "$CWD" rev-parse --verify HEAD >/dev/null 2>&1; then
  NONGIT_WARNING="Claude Fusion: $CWD is not a git repository (or has no commits), so the Stop-hook diff review is disabled for this session. Open a repository folder to re-enable it."
fi

mark_nogit_warned() {
  [ -n "$NONGIT_WARNING" ] || return 0
  clf_ensure_state_dir && : >"$NOGIT_MARKER" 2>/dev/null
}

finish_skip() {
  if [ -n "$NONGIT_WARNING" ]; then
    mark_nogit_warned
    NONGIT_WARNING="$NONGIT_WARNING" "$PY" -c 'import os, json; print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": os.environ.get("NONGIT_WARNING", "")}}))' 2>/dev/null
  fi
  exit 0
}

# --- escape hatch ---
case "$PROMPT" in *"[no-claude]"*) clf_dbg "skip: [no-claude]"; finish_skip;; esac
# --- re-fire guard: this prompt is our own Stop-hook continuation, not a fresh task ---
case "$PROMPT" in *"AUTOMATIC CLAUDE FUSION"*) clf_dbg "skip: own continuation"; finish_skip;; esac

# --- AGGRESSIVE gate: trigger unless clearly trivial / conversational / tiny ---
WORDS="$(printf '%s' "$PROMPT" | wc -w | tr -d ' ')"; WORDS="${WORDS:-0}"
[ "$WORDS" -lt 3 ] 2>/dev/null && { clf_dbg "skip: too short ($WORDS)"; finish_skip; }
FIRSTLINE="$(printf '%s' "$PROMPT" | sed -n '1p')"

# Action verbs. ACTION_RE gates the question check; STRONG_ACTION_RE (the unambiguous subset) means
# "real work" and overrides the trivial-edit heuristics below.
ACTION_RE='\b(implement|build|create|write|add|fix|debug|refactor|migrat|optimi[sz]|design|review|change|update|integrat|deploy|test|rewrite|redesign|secure|harden|delete|remove|configure|set ?up|wire|generate|scaffold|investigate|diagnose|profile)\b'
STRONG_ACTION_RE='\b(implement|build|create|refactor|redesign|rewrite|architect|design|deploy|scaffold|generate|debug|diagnose|profile|investigate|secure|harden|wire)\b|\b(migrat|optimi[sz]|integrat)[a-z]*'
HAS_STRONG=0
printf '%s' "$PROMPT" | grep -iqE "$STRONG_ACTION_RE" && HAS_STRONG=1

# 1) Whole-prompt conversational acknowledgement.
ACK_RE='^[[:space:]]*((thanks|thank you|thx|ok|okay|cool|nice|great|got it|hi|hello|hey|yo|sup|yes|no|sure|nvm|never ?mind|lgtm)[[:punct:][:space:]]*)+$'
printf '%s' "$PROMPT" | grep -ziqE "$ACK_RE" && { clf_dbg "skip: conversational"; finish_skip; }

# 1b) Short message opening with an acknowledgement and no action verb.
LEADING_ACK_RE='^[[:space:]]*(thanks|thank you|thx|ok|okay|cool|nice|great|got it|hi|hello|hey|yo|sup|yes|no|sure|nvm|never ?mind|lgtm)\b'
if [ "$WORDS" -lt 6 ] && [ "$HAS_STRONG" -eq 0 ] && printf '%s' "$FIRSTLINE" | grep -iqE "$LEADING_ACK_RE" && ! printf '%s' "$PROMPT" | grep -iqE "$ACTION_RE"; then
  clf_dbg "skip: conversational"; finish_skip
fi

# 2) Trivial micro-edits -- only when no strong action verb is present.
if [ "$HAS_STRONG" -eq 0 ]; then
  TRIVIAL_RE='fix(ing)? (a |the )?typo|\btypo\b|\brewor[dk]|\bwording\b|formatting|reindent|indentation|whitespace|\blint(ing)?\b|prettier|one[- ]?liner|spelling|capitali[sz]'
  printf '%s' "$PROMPT" | grep -iqE "$TRIVIAL_RE" && { clf_dbg "skip: trivial"; finish_skip; }
  printf '%s' "$PROMPT" | grep -ziqE '(add|fix|update|edit) (a |the )?comments?[[:space:]]*$' && { clf_dbg "skip: trivial"; finish_skip; }
  printf '%s' "$FIRSTLINE" | grep -iqE '^[[:space:]]*(rename|reformat|format)\b' && { clf_dbg "skip: trivial"; finish_skip; }
fi

# 3) Short, pure question with no coding-action verb -> skip.
QUESTION_RE='^[[:space:]]*(what|why|how|when|who|where|which|is|are|was|were|does|do|did|can|could|should|would|will|explain|describe|summari[sz]e|tell me|define|meaning of)\b'
if [ "$WORDS" -lt 16 ] && printf '%s' "$FIRSTLINE" | grep -iqE "$QUESTION_RE" && ! printf '%s' "$PROMPT" | grep -iqE "$ACTION_RE"; then
  clf_dbg "skip: short question"; finish_skip
fi
# -> everything else TRIGGERS Claude

if [ "${#CLAUDE_SAFE_ARGS[@]}" -gt 0 ] && ! clf_safe_mode_supported; then
  clf_dbg "skip: claude lacks --safe-mode; update Claude Code or set CLAUDE_FUSION_SAFE_MODE=0 to allow local Claude customizations"
  finish_skip
fi

# Gate says complex -> mark this session NOW, before consulting Claude, so the Stop hook still
# reviews the resulting diff even if this pre-edit analysis later times out or errors. The marker
# records the prompt-time HEAD so the Stop hook diffs against it even if Codex commits mid-turn
# (empty marker = non-git cwd; the Stop hook then falls back to HEAD).
if [ -n "$SESSION_ID" ] && clf_ensure_state_dir; then
  git -C "$CWD" rev-parse --verify HEAD >"$STATE_DIR/$SESSION_ID.complex" 2>/dev/null || true
fi

GITSTATUS="$(clf_filtered_status "$CWD" | head -c 4000)"
[ -n "$GITSTATUS" ] || GITSTATUS="(clean or not a git repository)"

WF_NOTE=""
if [ "$DEPTH" = "workflow" ] && [ "$CUSTOM_CLAUDE_CONTEXT" -eq 1 ]; then
  WF_NOTE="
When the task is non-trivial, run a thorough READ-ONLY multi-agent analysis (dynamic workflows /
parallel subagents) rather than a single quick pass. Do not edit files or run mutating commands."
elif [ "$DEPTH" = "workflow" ]; then
  WF_NOTE="
When the task is non-trivial, run a thorough READ-ONLY analysis rather than a single quick pass.
Claude Fusion is running you in --safe-mode, so do not rely on user/project Claude customizations,
skills, plugins, workflows, memory, MCP servers, or custom agents."
fi

CLAUDE_PREFIX=""
[ "$DEPTH" = "workflow" ] && [ "$CUSTOM_CLAUDE_CONTEXT" -eq 1 ] && CLAUDE_PREFIX="ultracode: "
CLAUDE_PROMPT="${CLAUDE_PREFIX}You are Claude acting as an independent coding peer for the OpenAI Codex agent.

You are running automatically from a Codex UserPromptSubmit hook, in READ-ONLY mode.
Do not edit files. Do not run destructive or mutating commands.
Do not inspect credentials, tokens, .env files, keychains, shell history, or auth files.
Focus only on the user's coding task and the repository context.$WF_NOTE

User task:
$PROMPT

Repository:
$CWD

Quick repo state:
$GITSTATUS

Return a concise analysis with:
1. Problem understanding
2. Recommended approach
3. Files or modules likely involved
4. Edge cases
5. Tests/checks Codex should run
6. Security or data-loss risks
7. Assumptions
8. Concise implementation strategy
9. Anything Codex should be skeptical about

Keep the final response under 1200 words. Prefer conservative, minimal changes.
Do not produce a full patch unless asked."

clf_build_claude_args
clf_dbg "running claude (model=$CLAUDE_MODEL, effort=$CLAUDE_EFFORT, depth=$DEPTH, tools=$TOOLSMODE, cwd=$CWD, words=$WORDS)"
clf_run_claude_with_retry
ANALYSIS="$CLF_OUTPUT"
RC="$CLF_RC"
[ "$RC" -eq 0 ] || { clf_dbg "claude rc=$RC -> skip"; finish_skip; }
[ -n "$ANALYSIS" ] || { clf_dbg "empty analysis -> skip"; finish_skip; }

PREAMBLE="AUTOMATIC CLAUDE FUSION CONTEXT:
Claude was automatically consulted (read-only) because this prompt matched the complex-coding gate.
Codex: before editing, form your own plan first, then reconcile it with Claude's analysis. Explicitly
note consensus, disagreements, Claude-only insights, and your final decision. You remain the final
judge and are not required to follow Claude. End your reply with a short Claude Fusion synthesis summary."

# Emit Codex's hook output. Codex's hook contract mirrors Claude Code's: a UserPromptSubmit hook
# injects model-visible context via hookSpecificOutput.additionalContext.
# Shell-side cap BEFORE the env handoff: a single env string over ~128KiB fails execve (E2BIG) and
# the python emitter (with its own finer truncation) would never run at all.
mark_nogit_warned
CLAUDE_ANALYSIS="$(clf_truncate_bytes "$ANALYSIS" 100000 "claude analysis")" PREAMBLE="$PREAMBLE" MAX_CHARS="$MAX_CHARS" NONGIT_WARNING="$NONGIT_WARNING" "$PY" <<'PY'
import os, json
a = os.environ.get("CLAUDE_ANALYSIS", "")
p = os.environ.get("PREAMBLE", "")
w = os.environ.get("NONGIT_WARNING", "")
try: m = int(os.environ.get("MAX_CHARS", "12000"))
except Exception: m = 12000
if len(a) > m:
    a = a[:m]
    cut = a.rfind("\n")
    if cut > 0:
        a = a[:cut]
    a += "\n\n[...Claude output truncated at " + str(m) + " chars...]"
ctx = p + "\n\n--- BEGIN CLAUDE ANALYSIS ---\n" + a + "\n--- END CLAUDE ANALYSIS ---"
if w:
    ctx = w + "\n\n" + ctx
print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}))
PY
clf_dbg "injected $(printf '%s' "$ANALYSIS" | wc -c) chars"
exit 0
