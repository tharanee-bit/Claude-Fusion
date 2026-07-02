#!/usr/bin/env bash
# Shared helpers for Claude Fusion hooks. This file is sourced by the hook scripts from their own
# directory; install.sh copies it into ~/.codex/hooks/ alongside them (it is not registered as a
# hook itself, so /hooks trust review does not list it).

clf_init_common() {
  CLF_LOG_PREFIX="$1"
  export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
  # Per-user state dir, mode 0700. On a shared /tmp a hostile co-tenant could otherwise pre-create a
  # predictable shared dir and read/delete our markers, so we also refuse a dir we do not own.
  STATE_DIR="${TMPDIR:-/tmp}/claude-fusion-state-$(id -u 2>/dev/null || echo 0)"
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
  # Workflow-depth analyses are slow; give them headroom. The internal timeout bounds the claude call;
  # the hook-registration timeout in hooks.json must sit comfortably above it (see install.sh / README).
  if [ "$DEPTH" = "workflow" ]; then DEF_TIMEOUT=600; else DEF_TIMEOUT=300; fi
  CLAUDE_TIMEOUT="${CLAUDE_FUSION_TIMEOUT:-$DEF_TIMEOUT}"
  CLF_MAX_FILE_BYTES="$(clf_positive_int "${CLAUDE_FUSION_MAX_FILE_BYTES:-409600}" 409600)"
  # Paths matched (lowercased, basename and full relative path) against these globs are dropped from
  # every git status and diff before anything is handed to Claude. Extend with CLAUDE_FUSION_EXCLUDE
  # (extra space-separated globs; globs containing spaces are unsupported).
  CLF_SENSITIVE_GLOBS='.env .env.* *.env .envrc
*.pem *.key *.p12 *.pfx *.jks *.keystore *.kdbx *.ppk
id_rsa* id_dsa* id_ecdsa* id_ed25519* *_rsa *_dsa *_ecdsa *_ed25519
credentials* *credentials.json secrets* secret.* *history .netrc _netrc .npmrc .pypirc .git-credentials .htpasswd auth.json
*.sqlite *.sqlite3 *.db
.ssh/* .aws/* .gnupg/*'
  [ -n "${CLAUDE_FUSION_EXCLUDE:-}" ] && CLF_SENSITIVE_GLOBS="$CLF_SENSITIVE_GLOBS $CLAUDE_FUSION_EXCLUDE"
}

clf_positive_int() {
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2";;
    0) printf '%s' "$2";;
    *) printf '%s' "$1";;
  esac
}

clf_ensure_state_dir() {
  mkdir -p -m 700 "$STATE_DIR" 2>/dev/null || return 1
  [ -O "$STATE_DIR" ] || return 1
}

clf_dbg() {
  [ "${CLAUDE_FUSION_DEBUG:-0}" = "1" ] || return 0
  clf_ensure_state_dir || return 0
  printf '%s %s: %s\n' "$$" "$CLF_LOG_PREFIX" "$*" >>"$STATE_DIR/debug.log"
}

clf_nested_fusion_active() {
  # Both Fusion directions set their flag before shelling out to the peer (env inherited through the
  # process tree); honoring either breaks any claude<->codex hook loop when both are installed.
  [ "${CLAUDE_FUSION_ACTIVE:-0}" = "1" ] || [ "${CODEX_FUSION_ACTIVE:-0}" = "1" ]
}

clf_setup_claude_runtime() {
  PY="/usr/bin/python3"
  [ -x "$PY" ] || PY="$(command -v python3 2>/dev/null)"
  [ -x "$PY" ] || { clf_dbg "no python3"; return 1; }

  command -v timeout >/dev/null 2>&1 || { clf_dbg "no timeout"; return 1; }

  # Resolve the claude binary, then put its real bin dir on PATH so claude's bundled runtime is reachable.
  CLAUDE_BIN="$(command -v claude 2>/dev/null)"
  if [ ! -x "$CLAUDE_BIN" ]; then
    for _cl_c in "$HOME/.local/bin/claude" "$HOME/bin/claude" "/usr/local/bin/claude" "$HOME/.npm-global/bin/claude"; do
      [ -x "$_cl_c" ] && { CLAUDE_BIN="$_cl_c"; break; }
    done
  fi
  [ -x "$CLAUDE_BIN" ] || { clf_dbg "no claude"; return 1; }

  _cl_dir="$(dirname "$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLAUDE_BIN" 2>/dev/null || echo "$CLAUDE_BIN")")"
  case ":$PATH:" in *":$_cl_dir:"*) ;; *) export PATH="$_cl_dir:$PATH";; esac
  return 0
}

clf_parse_fields() {
  # $1 = raw stdin JSON, remaining args = field names. Emits one base64 line per field so newlines
  # survive the shell. Codex's hook stdin schema matches Claude Code's (snake_case).
  _pf_input="$1"
  shift
  printf '%s' "$_pf_input" | "$PY" -c '
import sys, json, base64
try: d = json.load(sys.stdin)
except Exception: d = {}
for k in sys.argv[1:]:
    v = d.get(k, "")
    if isinstance(v, bool): v = "true" if v else "false"
    sys.stdout.write(base64.b64encode(str(v or "").encode()).decode() + "\n")
' "$@" 2>/dev/null
}

clf_field() {
  printf '%s' "$1" | sed -n "${2}p" | base64 -d 2>/dev/null
}

clf_sanitize_session_id() {
  # Sanitize before it becomes a filename under STATE_DIR (no path traversal / odd chars).
  case "$1" in *[!A-Za-z0-9._-]*|.|..) printf '';; *) printf '%s' "$1";; esac
}

clf_safe_mode_supported() {
  # Cached --help probe. The cache key is the resolved claude binary plus its mtime:size; claude
  # installs are versioned symlinks, so an update changes the realpath itself and re-probes
  # automatically (no TTL needed). Never cache a probe that produced no output (timeout/crash):
  # a transient hang must not permanently disable the harness.
  _sm_real="$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLAUDE_BIN" 2>/dev/null || printf '%s' "$CLAUDE_BIN")"
  _sm_stat="$(stat -c '%Y:%s' "$_sm_real" 2>/dev/null)"
  _sm_key="$_sm_real|${_sm_stat:-nostat}"
  _sm_cache="$STATE_DIR/claude-caps"
  if clf_ensure_state_dir && [ -f "$_sm_cache" ]; then
    IFS=$'\t' read -r _sm_ckey _sm_cval <"$_sm_cache" 2>/dev/null
    if [ "$_sm_ckey" = "$_sm_key" ]; then
      [ "$_sm_cval" = "1" ] && return 0
      [ "$_sm_cval" = "0" ] && return 1
    fi
  fi
  _sm_help="$(timeout 10 "$CLAUDE_BIN" --help 2>&1)"
  if printf '%s' "$_sm_help" | grep -q -- '--safe-mode'; then
    clf_ensure_state_dir && printf '%s\t1\n' "$_sm_key" >"$_sm_cache" 2>/dev/null
    return 0
  fi
  if [ -n "$_sm_help" ]; then
    clf_ensure_state_dir && printf '%s\t0\n' "$_sm_key" >"$_sm_cache" 2>/dev/null
  fi
  return 1
}

clf_sensitive_path() {
  _sp_path="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  _sp_base="${_sp_path##*/}"
  # set -f: the glob words must reach the case patterns literally, not expand against the cwd.
  set -f
  for _sp_g in $CLF_SENSITIVE_GLOBS; do
    case "$_sp_base" in $_sp_g) set +f; return 0;; esac
    case "$_sp_path" in $_sp_g|*/$_sp_g) set +f; return 0;; esac
  done
  set +f
  return 1
}

clf_filtered_status() {
  # git status --short with sensitive path names replaced by a placeholder (keeps the count signal).
  git -C "$1" status --short 2>/dev/null |
    while IFS= read -r _fs_line; do
      _fs_rest="${_fs_line:3}"
      _fs_old="$_fs_rest"
      _fs_new="$_fs_rest"
      case "$_fs_rest" in *' -> '*) _fs_old="${_fs_rest%% -> *}"; _fs_new="${_fs_rest##* -> }";; esac
      case "$_fs_old" in \"*\") _fs_old="${_fs_old#\"}"; _fs_old="${_fs_old%\"}";; esac
      case "$_fs_new" in \"*\") _fs_new="${_fs_new#\"}"; _fs_new="${_fs_new%\"}";; esac
      if clf_sensitive_path "$_fs_old" || clf_sensitive_path "$_fs_new"; then
        printf '%s [redacted sensitive path]\n' "${_fs_line:0:2}"
      else
        printf '%s\n' "$_fs_line"
      fi
    done
}

clf_filtered_diff() {
  # $1 = repo dir, $2 = base ref. Emits the diff with sensitive paths and files over the size cap
  # dropped entirely (the secret bytes never enter the payload). Returns 1 when nothing reviewable
  # remains. --name-only paths are toplevel-relative, so resolve sizes and run the final diff there.
  _fd_repo="$1"
  _fd_base="$2"
  _fd_top="$(git -C "$_fd_repo" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$_fd_top" ] || return 1
  _fd_files=()
  _fd_excluded=0
  while IFS= read -r -d '' _fd_f; do
    if clf_sensitive_path "$_fd_f"; then
      _fd_excluded=$((_fd_excluded + 1))
      continue
    fi
    _fd_sz="$(wc -c <"$_fd_top/$_fd_f" 2>/dev/null | tr -d ' ')"
    if [ "${_fd_sz:-0}" -gt "$CLF_MAX_FILE_BYTES" ]; then
      _fd_excluded=$((_fd_excluded + 1))
      continue
    fi
    _fd_files+=("$_fd_f")
  done < <(git -C "$_fd_repo" diff --name-only -z "$_fd_base" -- 2>/dev/null)
  [ "${#_fd_files[@]}" -gt 0 ] || return 1
  [ "$_fd_excluded" -gt 0 ] && printf '### note: %s changed file(s) excluded (sensitive path or size cap)\n' "$_fd_excluded"
  # :(literal) magic: pathspecs after -- are PATTERNS, so a changed file whose name looks like a
  # glob (e.g. ".en?") would otherwise re-match an excluded sibling (".env") and re-include its
  # content, and a name starting with ':' would be eaten as pathspec magic or abort git entirely.
  _fd_specs=()
  for _fd_f in "${_fd_files[@]}"; do
    _fd_specs+=(":(literal)$_fd_f")
  done
  git -C "$_fd_top" diff "$_fd_base" -- "${_fd_specs[@]}" 2>/dev/null
}

clf_truncate_bytes() {
  # $1 = text, $2 = byte cap, $3 = label for the marker. Cuts on a line boundary where possible and
  # appends an explicit marker so Claude knows it reviewed a partial payload.
  _tb_len="$(printf '%s' "$1" | wc -c | tr -d ' ')"
  if [ "${_tb_len:-0}" -le "$2" ]; then
    printf '%s' "$1"
    return 0
  fi
  _tb_head="$(printf '%s' "$1" | head -c "$2")"
  _tb_trim="${_tb_head%"${_tb_head##*$'\n'}"}"
  [ -n "$_tb_trim" ] && _tb_head="$_tb_trim"
  printf '%s\n[... %s truncated at %s bytes ...]\n' "$_tb_head" "$3" "$2"
}

clf_build_claude_args() {
  # Tool sandbox, built once and applied on EVERY attempt (including the retry) so a failed first
  # try can never silently widen Claude's tool access beyond what CLAUDE_FUSION_TOOLS asked for.
  if [ "$TOOLSMODE" = "none" ]; then
    CLAUDE_TOOL_ARGS=(--tools "")
  else
    _ba_allow="Read Grep Glob Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(git show:*) Bash(ls:*) Bash(cat:*)"
    [ "$DEPTH" = "workflow" ] && [ "$CUSTOM_CLAUDE_CONTEXT" -eq 1 ] && _ba_allow="$_ba_allow Task Workflow ToolSearch"
    CLAUDE_TOOL_ARGS=(--allowedTools "$_ba_allow")
  fi
  CLAUDE_ARGS=(-p "${CLAUDE_SAFE_ARGS[@]}" --permission-mode plan --no-session-persistence --output-format text)
  [ -n "$CLAUDE_MODEL" ] && CLAUDE_ARGS+=(--model "$CLAUDE_MODEL")
  [ -n "$CLAUDE_EFFORT" ] && CLAUDE_ARGS+=(--effort "$CLAUDE_EFFORT")
  CLAUDE_ARGS+=("${CLAUDE_TOOL_ARGS[@]}")
}

clf_run_claude() {
  # Read-only Claude invocation. plan mode forbids edits; the timeout wrapper guarantees the hook
  # can never hang Codex. Both Fusion-active flags mark the subtree so nested hooks short-circuit.
  printf '%s' "$CLAUDE_PROMPT" | CLAUDE_FUSION_ACTIVE=1 CODEX_FUSION_ACTIVE=1 timeout "$CLAUDE_TIMEOUT" \
    "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" 2>/dev/null
}

clf_run_claude_with_retry() {
  # Sets CLF_OUTPUT / CLF_RC. On a fast failure (e.g. unknown model/effort), retry once dropping only
  # --model/--effort. KEEP the tool sandbox so a failed first attempt can never widen tool access.
  # Timeouts (rc 124) are not retried.
  CLF_OUTPUT="$(clf_run_claude)"
  CLF_RC=$?
  if { [ "$CLF_RC" -ne 0 ] || [ -z "$CLF_OUTPUT" ]; } && [ "$CLF_RC" -ne 124 ]; then
    clf_dbg "claude rc=$CLF_RC / empty; retrying with default model+effort (sandbox preserved)"
    CLAUDE_ARGS=(-p "${CLAUDE_SAFE_ARGS[@]}" --permission-mode plan --no-session-persistence --output-format text "${CLAUDE_TOOL_ARGS[@]}")
    CLF_OUTPUT="$(clf_run_claude)"
    CLF_RC=$?
  fi
}

clf_first_nonempty_line() {
  printf '%s' "$1" | grep -m1 -vE '^[[:space:]]*$'
}
