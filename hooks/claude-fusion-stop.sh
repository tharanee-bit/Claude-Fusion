#!/usr/bin/env bash
# claude-fusion-stop.sh  (Codex Stop hook)
# When the finished task was gated-complex (marker from the UserPromptSubmit hook) AND there are
# working-tree changes, run Claude READ-ONLY over `git diff HEAD`. If Claude returns ISSUES_FOUND,
# block ONCE (decision:block) with the review. For Codex's Stop event, decision:block does not reject
# the turn -- it makes Codex continue, using `reason` as a new prompt. Loop-safe; never errors out.
set +e
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Recursion guard (see userprompt hook).
[ "${CLAUDE_FUSION_ACTIVE:-0}" = "1" ] && exit 0

# Per-user state dir, mode 0700 (see the UserPromptSubmit hook); refuse a dir we do not own.
STATE_DIR="${TMPDIR:-/tmp}/claude-fusion-state-$(id -u 2>/dev/null || echo 0)"
ensure_state_dir(){ mkdir -p -m 700 "$STATE_DIR" 2>/dev/null || return 1; [ -O "$STATE_DIR" ] || return 1; }
dbg(){ [ "${CLAUDE_FUSION_DEBUG:-0}" = "1" ] && ensure_state_dir && printf '%s STOP: %s\n' "$$" "$*" >>"$STATE_DIR/debug.log"; }

PY="/usr/bin/python3"; [ -x "$PY" ] || PY="$(command -v python3 2>/dev/null)"; [ -x "$PY" ] || exit 0
CLAUDE_BIN="$(command -v claude 2>/dev/null)"
if [ ! -x "$CLAUDE_BIN" ]; then
  for c in "$HOME/.local/bin/claude" "$HOME/bin/claude" "/usr/local/bin/claude" "$HOME/.npm-global/bin/claude"; do
    [ -x "$c" ] && { CLAUDE_BIN="$c"; break; }
  done
fi
[ -x "$CLAUDE_BIN" ] || exit 0
_cl_dir="$(dirname "$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLAUDE_BIN" 2>/dev/null || echo "$CLAUDE_BIN")")"
case ":$PATH:" in *":$_cl_dir:"*) ;; *) export PATH="$_cl_dir:$PATH";; esac

MAX_DIFF=20000; MAX_CHARS=12000
CLAUDE_MODEL="${CLAUDE_FUSION_MODEL:-opus}"
CLAUDE_EFFORT="${CLAUDE_FUSION_EFFORT:-xhigh}"
DEPTH="${CLAUDE_FUSION_DEPTH:-workflow}"
TOOLSMODE="${CLAUDE_FUSION_TOOLS:-readonly}"
if [ "$DEPTH" = "workflow" ]; then DEF_TIMEOUT=600; else DEF_TIMEOUT=300; fi
CLAUDE_TIMEOUT="${CLAUDE_FUSION_TIMEOUT:-$DEF_TIMEOUT}"

INPUT="$(cat)"; [ -n "$INPUT" ] || exit 0
FIELDS="$(printf '%s' "$INPUT" | "$PY" -c '
import sys,json,base64
try: d=json.load(sys.stdin)
except Exception: d={}
for k in ("cwd","session_id","stop_hook_active"):
    v=d.get(k,"")
    if isinstance(v,bool): v="true" if v else "false"
    sys.stdout.write(base64.b64encode(str(v or "").encode()).decode()+"\n")
' 2>/dev/null)"
CWD="$(printf '%s' "$FIELDS" | sed -n 1p | base64 -d 2>/dev/null)"
SESSION_ID="$(printf '%s' "$FIELDS" | sed -n 2p | base64 -d 2>/dev/null)"
STOP_ACTIVE="$(printf '%s' "$FIELDS" | sed -n 3p | base64 -d 2>/dev/null)"
case "$SESSION_ID" in *[!A-Za-z0-9._-]*|.|..) SESSION_ID="";; esac

# loop guard: we're already inside a continuation we forced -> don't review again
[ "$STOP_ACTIVE" = "true" ] && { dbg "stop_hook_active -> exit"; exit 0; }
[ -d "$CWD" ] || CWD="$PWD"

MARKER="$STATE_DIR/$SESSION_ID.complex"
[ -n "$SESSION_ID" ] && [ -f "$MARKER" ] || { dbg "no complex marker -> exit"; exit 0; }

DIFF="$(git -C "$CWD" diff HEAD 2>/dev/null | head -c "$MAX_DIFF")"
[ -n "$DIFF" ] || { dbg "empty diff -> exit"; rm -f "$MARKER" 2>/dev/null; exit 0; }
CHANGED="$(git -C "$CWD" status --short 2>/dev/null | head -c 3000)"
# NOTE: the marker is deleted only on a DEFINITIVE outcome (PASS, or a delivered ISSUES_FOUND block),
# not here. A transient failure leaves it so the next genuine Stop retries the review.

WF_NOTE=""
[ "$DEPTH" = "workflow" ] && WF_NOTE="
You may run a READ-ONLY multi-agent adversarial review (dynamic workflows / parallel subagents) for
deeper coverage. Do not edit files or run mutating commands."

CLAUDE_PROMPT="$([ "$DEPTH" = "workflow" ] && printf 'ultracode: ')You are Claude acting as an independent code reviewer for the OpenAI Codex agent.
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

# Tool sandbox, built once and applied on EVERY attempt (including the retry) so a failed first try
# can never silently widen Claude's tool access beyond what CLAUDE_FUSION_TOOLS asked for.
if [ "$TOOLSMODE" = "none" ]; then
  CLAUDE_TOOL_ARGS=(--tools "")
else
  ALLOW="Read Grep Glob Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(git show:*) Bash(ls:*) Bash(cat:*)"
  [ "$DEPTH" = "workflow" ] && ALLOW="$ALLOW Task Workflow ToolSearch"
  CLAUDE_TOOL_ARGS=(--allowedTools "$ALLOW")
fi
CLAUDE_ARGS=(-p --permission-mode plan --no-session-persistence --output-format text)
[ -n "$CLAUDE_MODEL" ] && CLAUDE_ARGS+=(--model "$CLAUDE_MODEL")
[ -n "$CLAUDE_EFFORT" ] && CLAUDE_ARGS+=(--effort "$CLAUDE_EFFORT")
CLAUDE_ARGS+=("${CLAUDE_TOOL_ARGS[@]}")

run_claude() {
  printf '%s' "$CLAUDE_PROMPT" | CLAUDE_FUSION_ACTIVE=1 timeout "$CLAUDE_TIMEOUT" \
    "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" 2>/dev/null
}
dbg "running claude review (model=$CLAUDE_MODEL, effort=$CLAUDE_EFFORT, depth=$DEPTH)"
REVIEW="$(run_claude)"; RC=$?
if { [ "$RC" -ne 0 ] || [ -z "$REVIEW" ]; } && [ "$RC" -ne 124 ]; then
  dbg "claude rc=$RC / empty; retrying with default model+effort (sandbox preserved)"
  CLAUDE_ARGS=(-p --permission-mode plan --no-session-persistence --output-format text "${CLAUDE_TOOL_ARGS[@]}")
  REVIEW="$(run_claude)"; RC=$?
fi
# On a transient failure, KEEP the marker so the next genuine Stop retries the review.
[ "$RC" -eq 0 ] || { dbg "claude rc!=0 -> exit (marker kept for retry)"; exit 0; }
[ -n "$REVIEW" ] || { dbg "empty review -> exit (marker kept)"; exit 0; }

# Claude responded: this is a definitive review, so consume the marker (review once).
rm -f "$MARKER" 2>/dev/null

# Only block when Claude explicitly flags issues. The verdict is the FIRST non-empty line, so check
# only that -- this also stops injected diff/prompt content from forging the control token.
VERDICT_LINE="$(printf '%s' "$REVIEW" | grep -m1 -vE '^[[:space:]]*$')"
if ! printf '%s' "$VERDICT_LINE" | grep -qiE 'CLAUDE_REVIEW_VERDICT:[[:space:]]*ISSUES_FOUND'; then
  dbg "verdict PASS/none -> exit"; exit 0
fi

REVIEW="$REVIEW" MAX_CHARS="$MAX_CHARS" "$PY" <<'PY'
import os, json
r = os.environ.get("REVIEW", "")
try: m = int(os.environ.get("MAX_CHARS", "12000"))
except Exception: m = 12000
if len(r) > m: r = r[:m] + "\n\n[...truncated...]"
reason = ("AUTOMATIC CLAUDE FUSION - POST-DIFF REVIEW:\n"
          "Claude independently reviewed your git diff and flagged potential issues. Address the "
          "serious problems (correctness, security, data-loss, concurrency, broken tests) before "
          "finalizing, or explicitly justify why each is not a real issue. You remain the final judge.\n\n" + r)
print(json.dumps({"decision": "block", "reason": reason}))
PY
dbg "blocked with ISSUES_FOUND"
exit 0
