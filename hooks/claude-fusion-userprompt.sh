#!/usr/bin/env bash
# claude-fusion-userprompt.sh  (Codex UserPromptSubmit hook)
# Auto-consult Claude Code (READ-ONLY) as an independent peer on non-trivial coding prompts and
# inject its analysis into Codex's context. Mirror image of Codex Fusion, reversed: here Codex is
# the primary agent and Claude is the advisor.
# GUARANTEE: never blocks Codex on the no-action path -- always exits 0. Escape hatch: [no-claude].
set +e
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Recursion guard: if we are already inside a Claude Fusion -> claude call (env inherited through the
# process tree), do nothing. This breaks any claude<->codex hook loop when both Fusions are installed.
[ "${CLAUDE_FUSION_ACTIVE:-0}" = "1" ] && exit 0

# Per-user state dir, mode 0700. On a shared /tmp a hostile co-tenant could otherwise pre-create a
# predictable shared dir and read/delete our markers, so we also refuse a dir we do not own.
STATE_DIR="${TMPDIR:-/tmp}/claude-fusion-state-$(id -u 2>/dev/null || echo 0)"
ensure_state_dir(){ mkdir -p -m 700 "$STATE_DIR" 2>/dev/null || return 1; [ -O "$STATE_DIR" ] || return 1; }
dbg(){ [ "${CLAUDE_FUSION_DEBUG:-0}" = "1" ] && ensure_state_dir && printf '%s UPS: %s\n' "$$" "$*" >>"$STATE_DIR/debug.log"; }

PY="/usr/bin/python3"; [ -x "$PY" ] || PY="$(command -v python3 2>/dev/null)"
[ -x "$PY" ] || { dbg "no python3"; exit 0; }
# Resolve the claude binary, then put its real bin dir on PATH so claude's bundled runtime is reachable.
CLAUDE_BIN="$(command -v claude 2>/dev/null)"
if [ ! -x "$CLAUDE_BIN" ]; then
  for c in "$HOME/.local/bin/claude" "$HOME/bin/claude" "/usr/local/bin/claude" "$HOME/.npm-global/bin/claude"; do
    [ -x "$c" ] && { CLAUDE_BIN="$c"; break; }
  done
fi
[ -x "$CLAUDE_BIN" ] || { dbg "no claude"; exit 0; }
_cl_dir="$(dirname "$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLAUDE_BIN" 2>/dev/null || echo "$CLAUDE_BIN")")"
case ":$PATH:" in *":$_cl_dir:"*) ;; *) export PATH="$_cl_dir:$PATH";; esac

MAX_CHARS=12000
# Claude Fusion runs Claude on the strongest model at extra-high (xhigh) effort and, by default,
# isolates Claude's local customizations so automatic consults stay task-scoped. Override via env.
CLAUDE_MODEL="${CLAUDE_FUSION_MODEL:-opus}"      # latest Opus by alias; bump when a stronger model ships
CLAUDE_EFFORT="${CLAUDE_FUSION_EFFORT:-xhigh}"   # low / medium / high / xhigh / max
DEPTH="${CLAUDE_FUSION_DEPTH:-workflow}"         # workflow (deeper pass) | single (one-shot)
TOOLSMODE="${CLAUDE_FUSION_TOOLS:-readonly}"     # readonly (explore repo) | none (--tools "", baked-in only)
SAFE_MODE="${CLAUDE_FUSION_SAFE_MODE:-1}"        # 1 isolates Claude customizations; 0 allows CLAUDE.md/memory/skills/workflows
CLAUDE_SAFE_ARGS=(--safe-mode)
case "$SAFE_MODE" in
  0|false|False|FALSE|no|No|NO|off|Off|OFF) CLAUDE_SAFE_ARGS=();;
esac
CUSTOM_CLAUDE_CONTEXT=0
[ "${#CLAUDE_SAFE_ARGS[@]}" -eq 0 ] && CUSTOM_CLAUDE_CONTEXT=1
claude_supports_safe_mode(){ timeout 10 "$CLAUDE_BIN" --help 2>&1 | grep -q -- '--safe-mode'; }
# Workflow-depth analyses are slow; give them headroom. The internal timeout bounds the claude call;
# the hook-registration timeout in hooks.json must sit comfortably above it (see install.sh / README).
if [ "$DEPTH" = "workflow" ]; then DEF_TIMEOUT=600; else DEF_TIMEOUT=300; fi
CLAUDE_TIMEOUT="${CLAUDE_FUSION_TIMEOUT:-$DEF_TIMEOUT}"

INPUT="$(cat)"; [ -n "$INPUT" ] || exit 0
# Parse prompt/cwd/session_id in one python call; base64 so newlines survive the shell.
# Codex's hook stdin schema matches Claude Code's (snake_case): prompt, cwd, session_id, ...
FIELDS="$(printf '%s' "$INPUT" | "$PY" -c '
import sys,json,base64
try: d=json.load(sys.stdin)
except Exception: d={}
for k in ("prompt","cwd","session_id"):
    sys.stdout.write(base64.b64encode(str(d.get(k,"") or "").encode()).decode()+"\n")
' 2>/dev/null)"
PROMPT="$(printf '%s' "$FIELDS" | sed -n 1p | base64 -d 2>/dev/null)"
CWD="$(printf '%s' "$FIELDS" | sed -n 2p | base64 -d 2>/dev/null)"
SESSION_ID="$(printf '%s' "$FIELDS" | sed -n 3p | base64 -d 2>/dev/null)"
# Sanitize session_id before it becomes a filename under STATE_DIR (no path traversal / odd chars).
case "$SESSION_ID" in *[!A-Za-z0-9._-]*|.|..) SESSION_ID="";; esac
[ -n "$PROMPT" ] || exit 0
[ -d "$CWD" ] || CWD="$PWD"

# --- escape hatch ---
case "$PROMPT" in *"[no-claude]"*) dbg "skip: [no-claude]"; exit 0;; esac
# --- re-fire guard: this prompt is our own Stop-hook continuation, not a fresh task ---
case "$PROMPT" in *"AUTOMATIC CLAUDE FUSION"*) dbg "skip: own continuation"; exit 0;; esac

# --- AGGRESSIVE gate: trigger unless clearly trivial / conversational / tiny ---
WORDS="$(printf '%s' "$PROMPT" | wc -w | tr -d ' ')"; WORDS="${WORDS:-0}"
[ "$WORDS" -lt 3 ] 2>/dev/null && { dbg "skip: too short ($WORDS)"; exit 0; }
FIRSTLINE="$(printf '%s' "$PROMPT" | sed -n '1p')"

# Action verbs. ACTION_RE gates the question check; STRONG_ACTION_RE (the unambiguous subset) means
# "real work" and overrides the trivial-edit heuristics below.
ACTION_RE='\b(implement|build|create|write|add|fix|debug|refactor|migrat|optimi[sz]|design|review|change|update|integrat|deploy|test|rewrite|redesign|secure|harden|delete|remove|configure|set ?up|wire|generate|scaffold|investigate|diagnose|profile)\b'
STRONG_ACTION_RE='\b(implement|build|create|refactor|redesign|rewrite|architect|design|deploy|scaffold|generate|debug|diagnose|profile|investigate|secure|harden|wire)\b|\b(migrat|optimi[sz]|integrat)[a-z]*'
HAS_STRONG=0
printf '%s' "$PROMPT" | grep -iqE "$STRONG_ACTION_RE" && HAS_STRONG=1

# 1) Whole-prompt conversational acknowledgement.
ACK_RE='^[[:space:]]*((thanks|thank you|thx|ok|okay|cool|nice|great|got it|hi|hello|hey|yo|sup|yes|no|sure|nvm|never ?mind|lgtm)[[:punct:][:space:]]*)+$'
printf '%s' "$PROMPT" | grep -ziqE "$ACK_RE" && { dbg "skip: conversational"; exit 0; }

# 1b) Short message opening with an acknowledgement and no action verb.
LEADING_ACK_RE='^[[:space:]]*(thanks|thank you|thx|ok|okay|cool|nice|great|got it|hi|hello|hey|yo|sup|yes|no|sure|nvm|never ?mind|lgtm)\b'
if [ "$WORDS" -lt 6 ] && [ "$HAS_STRONG" -eq 0 ] && printf '%s' "$FIRSTLINE" | grep -iqE "$LEADING_ACK_RE" && ! printf '%s' "$PROMPT" | grep -iqE "$ACTION_RE"; then
  dbg "skip: conversational"; exit 0
fi

# 2) Trivial micro-edits -- only when no strong action verb is present.
if [ "$HAS_STRONG" -eq 0 ]; then
  TRIVIAL_RE='fix(ing)? (a |the )?typo|\btypo\b|\brewor[dk]|\bwording\b|formatting|reindent|indentation|whitespace|\blint(ing)?\b|prettier|one[- ]?liner|spelling|capitali[sz]'
  printf '%s' "$PROMPT" | grep -iqE "$TRIVIAL_RE" && { dbg "skip: trivial"; exit 0; }
  printf '%s' "$PROMPT" | grep -ziqE '(add|fix|update|edit) (a |the )?comments?[[:space:]]*$' && { dbg "skip: trivial"; exit 0; }
  printf '%s' "$FIRSTLINE" | grep -iqE '^[[:space:]]*(rename|reformat|format)\b' && { dbg "skip: trivial"; exit 0; }
fi

# 3) Short, pure question with no coding-action verb -> skip.
QUESTION_RE='^[[:space:]]*(what|why|how|when|who|where|which|is|are|was|were|does|do|did|can|could|should|would|will|explain|describe|summari[sz]e|tell me|define|meaning of)\b'
if [ "$WORDS" -lt 16 ] && printf '%s' "$FIRSTLINE" | grep -iqE "$QUESTION_RE" && ! printf '%s' "$PROMPT" | grep -iqE "$ACTION_RE"; then
  dbg "skip: short question"; exit 0
fi
# -> everything else TRIGGERS Claude

if [ "${#CLAUDE_SAFE_ARGS[@]}" -gt 0 ] && ! claude_supports_safe_mode; then
  dbg "skip: claude lacks --safe-mode; update Claude Code or set CLAUDE_FUSION_SAFE_MODE=0 to allow local Claude customizations"
  exit 0
fi

# Gate says complex -> mark this session NOW, before consulting Claude, so the Stop hook still
# reviews the resulting diff even if this pre-edit analysis later times out or errors.
[ -n "$SESSION_ID" ] && ensure_state_dir && : >"$STATE_DIR/$SESSION_ID.complex" 2>/dev/null

GITSTATUS="$(git -C "$CWD" status --short 2>/dev/null | head -c 4000)"
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

# Read-only Claude invocation. plan mode forbids edits; the timeout wrapper guarantees the hook
# can never hang Codex. CLAUDE_FUSION_ACTIVE=1 marks the subtree so nested hooks short-circuit.
# Tool sandbox, built once and applied on EVERY attempt (including the retry) so a failed first try
# can never silently widen Claude's tool access beyond what CLAUDE_FUSION_TOOLS asked for.
if [ "$TOOLSMODE" = "none" ]; then
  CLAUDE_TOOL_ARGS=(--tools "")
else
  ALLOW="Read Grep Glob Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(git show:*) Bash(ls:*) Bash(cat:*)"
  [ "$DEPTH" = "workflow" ] && [ "$CUSTOM_CLAUDE_CONTEXT" -eq 1 ] && ALLOW="$ALLOW Task Workflow ToolSearch"
  CLAUDE_TOOL_ARGS=(--allowedTools "$ALLOW")
fi
CLAUDE_ARGS=(-p "${CLAUDE_SAFE_ARGS[@]}" --permission-mode plan --no-session-persistence --output-format text)
[ -n "$CLAUDE_MODEL" ] && CLAUDE_ARGS+=(--model "$CLAUDE_MODEL")
[ -n "$CLAUDE_EFFORT" ] && CLAUDE_ARGS+=(--effort "$CLAUDE_EFFORT")
CLAUDE_ARGS+=("${CLAUDE_TOOL_ARGS[@]}")

run_claude() {
  printf '%s' "$CLAUDE_PROMPT" | CLAUDE_FUSION_ACTIVE=1 timeout "$CLAUDE_TIMEOUT" \
    "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" 2>/dev/null
}
dbg "running claude (model=$CLAUDE_MODEL, effort=$CLAUDE_EFFORT, depth=$DEPTH, tools=$TOOLSMODE, cwd=$CWD, words=$WORDS)"
ANALYSIS="$(run_claude)"; RC=$?
# On a fast failure (e.g. unknown model/effort), retry once dropping only --model/--effort. KEEP the
# tool sandbox so a failed first attempt can never widen Claude's tool access.
if { [ "$RC" -ne 0 ] || [ -z "$ANALYSIS" ]; } && [ "$RC" -ne 124 ]; then
  dbg "claude rc=$RC / empty; retrying with default model+effort (sandbox preserved)"
  CLAUDE_ARGS=(-p "${CLAUDE_SAFE_ARGS[@]}" --permission-mode plan --no-session-persistence --output-format text "${CLAUDE_TOOL_ARGS[@]}")
  ANALYSIS="$(run_claude)"; RC=$?
fi
[ "$RC" -eq 0 ] || { dbg "claude rc=$RC -> skip"; exit 0; }
[ -n "$ANALYSIS" ] || { dbg "empty analysis -> skip"; exit 0; }

PREAMBLE="AUTOMATIC CLAUDE FUSION CONTEXT:
Claude was automatically consulted (read-only) because this prompt matched the complex-coding gate.
Codex: before editing, form your own plan first, then reconcile it with Claude's analysis. Explicitly
note consensus, disagreements, Claude-only insights, and your final decision. You remain the final
judge and are not required to follow Claude. End your reply with a short Claude Fusion synthesis summary."

# Emit Codex's hook output. Codex's hook contract mirrors Claude Code's: a UserPromptSubmit hook
# injects model-visible context via hookSpecificOutput.additionalContext.
CLAUDE_ANALYSIS="$ANALYSIS" PREAMBLE="$PREAMBLE" MAX_CHARS="$MAX_CHARS" "$PY" <<'PY'
import os, json
a = os.environ.get("CLAUDE_ANALYSIS", "")
p = os.environ.get("PREAMBLE", "")
try: m = int(os.environ.get("MAX_CHARS", "12000"))
except Exception: m = 12000
if len(a) > m: a = a[:m] + "\n\n[...Claude output truncated...]"
ctx = p + "\n\n--- BEGIN CLAUDE ANALYSIS ---\n" + a + "\n--- END CLAUDE ANALYSIS ---"
print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}))
PY
dbg "injected $(printf '%s' "$ANALYSIS" | wc -c) chars"
exit 0
