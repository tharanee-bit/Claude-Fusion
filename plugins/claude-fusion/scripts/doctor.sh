#!/usr/bin/env bash
# Claude Fusion doctor: read-only diagnostics for plugin and legacy installs.
set -u

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
HOOKS_FILE="$CODEX_DIR/hooks.json"
EXPECT="${1:-auto}"
FAILURES=0
WARNINGS=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf 'WARN  %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL  %s\n' "$*"; }

printf 'Claude Fusion doctor (read-only)\n'
printf 'Plugin root: %s\n' "$PLUGIN_ROOT"
printf 'Codex home:  %s\n\n' "$CODEX_DIR"

PY="$(command -v python3 2>/dev/null || true)"
CODEX_BIN="$(command -v codex 2>/dev/null || true)"
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"
GIT_BIN="$(command -v git 2>/dev/null || true)"

[ -n "$PY" ] && pass "python3: $($PY --version 2>&1)" || fail "python3 is required"
[ -n "$GIT_BIN" ] && pass "git: $($GIT_BIN --version 2>&1)" || fail "git is required"
[ -n "$TIMEOUT_BIN" ] && pass "timeout command is available" || fail "GNU timeout is required"
[ -n "$CODEX_BIN" ] && pass "Codex: $($CODEX_BIN --version 2>&1 | tail -n 1)" || fail "codex is not on PATH"
[ -n "$CLAUDE_BIN" ] && pass "Claude Code: $($CLAUDE_BIN --version 2>&1 | head -n 1)" || warn "claude is not on PATH; hooks will fail open"

for script in claude-fusion-userprompt.sh claude-fusion-subagent-stop.sh claude-fusion-stop.sh; do
  [ -x "$PLUGIN_ROOT/hooks/$script" ] && pass "$script is executable" || fail "$PLUGIN_ROOT/hooks/$script is not executable"
done
[ -r "$PLUGIN_ROOT/hooks/claude-fusion-common.sh" ] && pass "shared hook helper is readable" || fail "shared hook helper is missing"

if [ -n "$PY" ]; then
  _doctor_python="$(CF_PLUGIN_ROOT="$PLUGIN_ROOT" CF_HOOKS_FILE="$HOOKS_FILE" CF_CODEX_DIR="$CODEX_DIR" "$PY" - <<'PY'
import hashlib, json, os, pathlib, re, stat, subprocess, sys

root = pathlib.Path(os.environ["CF_PLUGIN_ROOT"])
hooks_file = pathlib.Path(os.environ["CF_HOOKS_FILE"])
codex_dir = pathlib.Path(os.environ["CF_CODEX_DIR"])
failures = 0
warnings = 0

def report(level, message):
    global failures, warnings
    print(f"{level:<5} {message}")
    if level == "FAIL": failures += 1
    elif level == "WARN": warnings += 1

try:
    manifest = json.loads((root / ".codex-plugin/plugin.json").read_text())
    required = (manifest.get("name") == "claude-fusion" and
                re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", manifest.get("version", "")) and
                manifest.get("license") == "MIT")
    report("PASS" if required else "FAIL", "plugin manifest has normalized name, semantic version, and MIT metadata")
except Exception as exc:
    report("FAIL", f"plugin manifest is invalid JSON: {exc}")

try:
    hooks = json.loads((root / "hooks/hooks.json").read_text())["hooks"]
    expected = {"UserPromptSubmit", "SubagentStop", "Stop"}
    commands = {event: [h for group in hooks.get(event, []) for h in group.get("hooks", [])] for event in expected}
    valid = set(hooks) == expected and all(len(commands[e]) == 1 for e in expected)
    valid = valid and all("${PLUGIN_ROOT}/hooks/claude-fusion-" in commands[e][0].get("command", "") for e in expected)
    valid = valid and all(commands[e][0].get("statusMessage") for e in expected)
    report("PASS" if valid else "FAIL", "plugin hooks register exactly UserPromptSubmit, SubagentStop, and Stop through ${PLUGIN_ROOT}")
    internal_max = 630
    timeouts = [commands[e][0].get("timeout", 0) for e in expected]
    report("PASS" if all(isinstance(t, int) and t > internal_max for t in timeouts) else "FAIL",
           "hook registration timeouts exceed the maximum shared internal budget")
except Exception as exc:
    report("FAIL", f"plugin hooks manifest is invalid: {exc}")

legacy_commands = []
if hooks_file.exists():
    try:
        data = json.loads(hooks_file.read_text())
        container = data.get("hooks", data) if isinstance(data, dict) else {}
        for event in ("UserPromptSubmit", "SubagentStop", "Stop"):
            for group in container.get(event, []):
                for hook in group.get("hooks", []):
                    command = hook.get("command", "")
                    if "claude-fusion" in command:
                        legacy_commands.append((event, command))
        counts = {event: sum(1 for e, _ in legacy_commands if e == event) for event in ("UserPromptSubmit", "SubagentStop", "Stop")}
        report("PASS" if all(v <= 1 for v in counts.values()) else "FAIL", "legacy hooks.json has no duplicate Claude Fusion registration per event")
    except Exception as exc:
        report("FAIL", f"legacy hooks.json is invalid JSON: {exc}")
else:
    report("PASS", "no legacy hooks.json registrations detected")

legacy_files = [codex_dir / "hooks" / name for name in (
    "claude-fusion-common.sh", "claude-fusion-userprompt.sh", "claude-fusion-subagent-stop.sh", "claude-fusion-stop.sh"
)]
legacy_present = bool(legacy_commands or any(path.exists() for path in legacy_files))
print("INFO  legacy installation detected" if legacy_present else "INFO  no legacy installation detected")

state = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / f"claude-fusion-state-{os.getuid()}"
parent_safe = state.parent.exists() and state.parent.stat().st_uid in (os.getuid(), 0)
if state.exists():
    mode = stat.S_IMODE(state.stat().st_mode)
    safe = not state.is_symlink() and state.is_dir() and state.stat().st_uid == os.getuid() and mode & 0o077 == 0
    report("PASS" if safe else "FAIL", f"state directory ownership/mode is safe: {state}")
else:
    report("PASS" if parent_safe else "WARN", f"state directory is absent; planned location is {state}")

common = (root / "hooks/claude-fusion-common.sh").read_text(errors="replace")
readonly = all(token in common for token in ("--permission-mode plan", "--no-session-persistence", "Bash(git status:*)", "Bash(git diff:*)"))
report("PASS" if readonly else "FAIL", "canonical runtime retains plan mode, ephemeral default, and read-only tool allowlist")

# Locate installed cache copies without modifying or trusting Codex internals. Compare only exact
# same-name runtime files; absence is informational for a source-checkout/legacy doctor run.
cache_root = codex_dir / "plugins" / "cache"
cache_plugins = []
if cache_root.exists():
    for path in cache_root.glob("**/.codex-plugin/plugin.json"):
        try:
            if json.loads(path.read_text()).get("name") == "claude-fusion": cache_plugins.append(path.parent.parent)
        except Exception:
            pass
parity_files = (
    ".codex-plugin/plugin.json", "hooks/hooks.json", "hooks/claude-fusion-common.sh",
    "hooks/claude-fusion-userprompt.sh", "hooks/claude-fusion-subagent-stop.sh",
    "hooks/claude-fusion-stop.sh", "skills/claude-fusion-auto/SKILL.md", "scripts/doctor.sh",
)
if cache_plugins:
    def digest(path): return hashlib.sha256(path.read_bytes()).digest()
    parity = any(all((candidate / rel).is_file() and digest(candidate / rel) == digest(root / rel)
                     for rel in parity_files) for candidate in cache_plugins)
    report("PASS" if parity else "WARN", "an installed plugin cache matches every distributable source file")
else:
    print("INFO  no Claude Fusion plugin cache was discoverable for parity comparison")

print(f"DOCTOR_COUNTS {failures} {warnings}")
PY
  )"
  _py_rc=$?
  printf '%s\n' "$_doctor_python" | sed '/^DOCTOR_COUNTS /d'
  _counts="$(printf '%s\n' "$_doctor_python" | sed -n 's/^DOCTOR_COUNTS //p' | tail -n 1)"
  read -r _py_failures _py_warnings <<<"$_counts"
  FAILURES=$((FAILURES + ${_py_failures:-0}))
  WARNINGS=$((WARNINGS + ${_py_warnings:-0}))
  [ "$_py_rc" -eq 0 ] || fail "embedded manifest diagnostics crashed"
fi

PLUGIN_INSTALLED=0
if [ -n "$CODEX_BIN" ]; then
  PLUGIN_JSON="$($CODEX_BIN plugin list --json 2>/dev/null || true)"
  if [ -n "$PY" ] && printf '%s' "$PLUGIN_JSON" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(x.get("pluginId")=="claude-fusion@claude-fusion" and x.get("installed") for x in d.get("installed",[])) else 1)' 2>/dev/null; then
    PLUGIN_INSTALLED=1
    pass "claude-fusion@claude-fusion is installed"
  else
    warn "claude-fusion@claude-fusion is not reported as installed"
  fi
fi

LEGACY_PRESENT=0
if [ -f "$HOOKS_FILE" ] && grep -q 'claude-fusion' "$HOOKS_FILE" 2>/dev/null; then LEGACY_PRESENT=1; fi
[ -e "$CODEX_DIR/hooks/claude-fusion-userprompt.sh" ] && LEGACY_PRESENT=1
if [ "$PLUGIN_INSTALLED" -eq 1 ] && [ "$LEGACY_PRESENT" -eq 1 ]; then
  fail "plugin and legacy registrations/files coexist; enable exactly one installation mode"
elif [ "$EXPECT" = "plugin" ] && [ "$PLUGIN_INSTALLED" -ne 1 ]; then
  fail "plugin installation was expected but not detected"
elif [ "$EXPECT" = "legacy" ] && [ "$LEGACY_PRESENT" -ne 1 ]; then
  fail "legacy installation was expected but not detected"
else
  pass "plugin/legacy installation modes are not simultaneously enabled"
fi

if [ -n "$CLAUDE_BIN" ]; then
  HELP="$(timeout 10 "$CLAUDE_BIN" --help 2>&1 || true)"
  for capability in --safe-mode --output-format --json-schema --resume; do
    printf '%s' "$HELP" | grep -q -- "$capability" && pass "Claude supports $capability" || warn "Claude lacks $capability; compatibility fallback may apply"
  done
fi

warn "MANDATORY HUMAN GATE: open /hooks in a new Codex session and trust the three Claude Fusion hooks"
printf '\nDoctor complete: %s failure(s), %s warning(s). No files were changed.\n' "$FAILURES" "$WARNINGS"
[ "$FAILURES" -eq 0 ]
