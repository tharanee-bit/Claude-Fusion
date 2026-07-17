#!/usr/bin/env bash
# Claude Fusion installer. Plugin-first by default; --local uses this checkout and --legacy keeps
# the historical copy-and-merge path. Marketplace configuration is changed only through Codex CLI.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$HERE/plugins/claude-fusion"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
HOOKS_DIR="$CODEX_DIR/hooks"
SKILLS_DIR="$CODEX_DIR/skills"
HOOKS_FILE="$CODEX_DIR/hooks.json"
CONFIG_FILE="$CODEX_DIR/config.toml"
HOOK_TIMEOUT=660
MARKETPLACE_NAME=claude-fusion
PLUGIN_SELECTOR=claude-fusion@claude-fusion
REMOTE_SOURCE=tharanee-bit/Claude-Fusion
MODE=remote

usage() {
  echo "Usage: ./install.sh [--local | --legacy]"
  echo "  default   install/update from $REMOTE_SOURCE through the Codex plugin CLI"
  echo "  --local   install the plugin from this checkout for development"
  echo "  --legacy  copy hooks/skill into CODEX_HOME and merge hooks.json"
}

case "${1:-}" in
  "") ;;
  --local) MODE=local;;
  --legacy) MODE=legacy;;
  -h|--help) usage; exit 0;;
  *) usage >&2; exit 2;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

PY="$(command -v python3 2>/dev/null || true)"
[ -n "$PY" ] || { echo "ERROR: python3 is required." >&2; exit 1; }
mkdir -p "$CODEX_DIR"

plugin_installed() {
  codex plugin list --json 2>/dev/null | "$PY" -c '
import json, sys
try: data = json.load(sys.stdin)
except Exception: raise SystemExit(1)
raise SystemExit(0 if any(x.get("pluginId") == "claude-fusion@claude-fusion" and x.get("installed") for x in data.get("installed", [])) else 1)
' 2>/dev/null
}

marketplace_info() {
  codex plugin marketplace list --json 2>/dev/null | "$PY" -c '
import json, sys
name = sys.argv[1]
try: data = json.load(sys.stdin)
except Exception: raise SystemExit(1)
for item in data.get("marketplaces", []):
    if item.get("name") == name:
        source = item.get("marketplaceSource") or {}
        print("\t".join((item.get("root", ""), source.get("sourceType", ""), source.get("source", ""))))
        raise SystemExit(0)
raise SystemExit(1)
' "$MARKETPLACE_NAME" 2>/dev/null
}

remove_legacy() {
  # Called only after a plugin install has been verified. The Python helper backs up hooks.json and
  # atomically removes all legacy Claude Fusion registrations while preserving unrelated hooks.
  if [ -f "$HOOKS_FILE" ]; then
    CF_HOOKS_FILE="$HOOKS_FILE" "$PY" - <<'PY'
import json, os, shutil, tempfile
path = os.path.realpath(os.environ["CF_HOOKS_FILE"])
with open(path) as f: data = json.load(f)
if not isinstance(data, dict): raise SystemExit("hooks.json is not a JSON object")
container = data["hooks"] if isinstance(data.get("hooks"), dict) else data
removed = 0
for event in ("UserPromptSubmit", "SubagentStop", "Stop"):
    groups = []
    for group in container.get(event, []):
        hooks = group.get("hooks", [])
        kept = [h for h in hooks if "claude-fusion" not in (h.get("command") or "")]
        removed += len(hooks) - len(kept)
        if kept:
            copy = dict(group); copy["hooks"] = kept; groups.append(copy)
    if groups: container[event] = groups
    elif event in container: del container[event]
if isinstance(data.get("hooks"), dict) and not data["hooks"]: del data["hooks"]
if removed:
    shutil.copy2(path, path + ".claude-fusion.bak")
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".hooks.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
    print(f"Removed {removed} legacy hook registration(s); backup: {path}.claude-fusion.bak")
PY
  fi
  rm -f "$HOOKS_DIR/claude-fusion-common.sh" "$HOOKS_DIR/claude-fusion-userprompt.sh" \
    "$HOOKS_DIR/claude-fusion-subagent-stop.sh" "$HOOKS_DIR/claude-fusion-stop.sh"
  rm -f "$SKILLS_DIR/claude-fusion-auto/SKILL.md"
  rmdir "$SKILLS_DIR/claude-fusion-auto" 2>/dev/null || true
}

install_legacy() {
  # Explicitly remove a plugin install first: plugin and legacy registrations must never coexist.
  if command -v codex >/dev/null 2>&1 && plugin_installed; then
    codex plugin remove "$PLUGIN_SELECTOR"
  fi
  mkdir -p "$HOOKS_DIR" "$SKILLS_DIR/claude-fusion-auto"
  install -m 0644 "$PLUGIN_ROOT/hooks/claude-fusion-common.sh" "$HOOKS_DIR/claude-fusion-common.sh"
  install -m 0755 "$PLUGIN_ROOT/hooks/claude-fusion-userprompt.sh" "$HOOKS_DIR/claude-fusion-userprompt.sh"
  install -m 0755 "$PLUGIN_ROOT/hooks/claude-fusion-subagent-stop.sh" "$HOOKS_DIR/claude-fusion-subagent-stop.sh"
  install -m 0755 "$PLUGIN_ROOT/hooks/claude-fusion-stop.sh" "$HOOKS_DIR/claude-fusion-stop.sh"
  install -m 0644 "$PLUGIN_ROOT/skills/claude-fusion-auto/SKILL.md" "$SKILLS_DIR/claude-fusion-auto/SKILL.md"

  CF_UPS="$HOOKS_DIR/claude-fusion-userprompt.sh" \
  CF_SUBSTOP="$HOOKS_DIR/claude-fusion-subagent-stop.sh" \
  CF_STOP="$HOOKS_DIR/claude-fusion-stop.sh" \
  CF_HOOKS_FILE="$HOOKS_FILE" CF_CONFIG="$CONFIG_FILE" CF_TIMEOUT="$HOOK_TIMEOUT" "$PY" - <<'PY'
import json, os, shutil, sys, tempfile
path = os.path.realpath(os.environ["CF_HOOKS_FILE"])
timeout = int(os.environ["CF_TIMEOUT"])
original = None
data = {}
if os.path.exists(path):
    try:
        original = open(path).read(); data = json.loads(original)
    except Exception as exc:
        raise SystemExit(f"ERROR: {path} is not valid JSON ({exc}); refusing to overwrite it")
if not isinstance(data, dict): raise SystemExit("ERROR: hooks.json is not a JSON object")
events = ("UserPromptSubmit", "Stop", "SessionStart", "PreToolUse", "PostToolUse",
          "PermissionRequest", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop")
if isinstance(data.get("hooks"), dict): container = data["hooks"]
elif any(key in data for key in events): container = data
else: data["hooks"] = {}; container = data["hooks"]

def norm(value): return os.path.normpath(os.path.expanduser(os.path.expandvars(value or "")))
def ensure(event, command, status):
    target = norm(command)
    groups = container.setdefault(event, [])
    for group in groups:
        for hook in group.get("hooks", []):
            if norm(hook.get("command")) == target:
                before = dict(hook)
                hook.update(type="command", timeout=timeout, statusMessage=status)
                return hook != before
    groups.append({"hooks": [{"type": "command", "command": command, "timeout": timeout, "statusMessage": status}]})
    return True

changed = [
    ensure("UserPromptSubmit", os.environ["CF_UPS"], "Claude Fusion is analyzing the task read-only"),
    ensure("SubagentStop", os.environ["CF_SUBSTOP"], "Claude Fusion is reviewing the subagent result read-only"),
    ensure("Stop", os.environ["CF_STOP"], "Claude Fusion is reviewing the final diff read-only"),
]
if any(changed):
    if original is not None: shutil.copy2(path, path + ".claude-fusion.bak")
    directory = os.path.dirname(path) or "."; os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".hooks.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
    print("hooks.json merged for UserPromptSubmit, SubagentStop, and Stop")
else:
    print("hooks.json already has the Claude Fusion hooks; nothing to change.")

cfg = os.environ.get("CF_CONFIG", "")
if cfg and os.path.exists(cfg):
    try:
        import tomllib
        hooks_cfg = tomllib.load(open(cfg, "rb")).get("hooks")
        if isinstance(hooks_cfg, dict) and any(e in hooks_cfg for e in events):
            print("WARNING: config.toml also defines hooks; remove duplicate Claude Fusion registrations.", file=sys.stderr)
    except Exception: pass
PY
  "$PLUGIN_ROOT/scripts/doctor.sh" legacy
}

install_plugin() {
  command -v codex >/dev/null 2>&1 || { echo "ERROR: codex is required for plugin installation." >&2; exit 1; }
  if [ -f "$HOOKS_FILE" ]; then
    CF_HOOKS_FILE="$HOOKS_FILE" "$PY" -c '
import json, os, sys
path = os.path.realpath(os.environ["CF_HOOKS_FILE"])
try: data = json.load(open(path))
except Exception as exc: raise SystemExit(f"ERROR: {path} is not valid JSON ({exc}); plugin migration aborted before changing installations")
if not isinstance(data, dict): raise SystemExit(f"ERROR: {path} is not a JSON object; plugin migration aborted")
' || exit 1
  fi
  existing_info="$(marketplace_info || true)"
  IFS=$'\t' read -r existing_root existing_type existing_source <<<"$existing_info"
  if [ "$MODE" = "local" ]; then
    desired_source="$HERE"
    if [ -n "$existing_root" ] && { [ "$existing_type" = "git" ] || [ "$(realpath "$existing_root" 2>/dev/null || printf '%s' "$existing_root")" != "$HERE" ]; }; then
      codex plugin marketplace remove "$MARKETPLACE_NAME"
      existing_root=""
    fi
    [ -n "$existing_root" ] || codex plugin marketplace add "$desired_source"
  else
    if [ -n "$existing_root" ] && { [ "$existing_type" = "local" ] || { [ -n "$existing_source" ] && [ "$existing_source" != "$REMOTE_SOURCE" ]; }; }; then
      codex plugin marketplace remove "$MARKETPLACE_NAME"
      existing_root=""
    fi
    if [ -n "$existing_root" ]; then
      codex plugin marketplace upgrade "$MARKETPLACE_NAME"
    else
      codex plugin marketplace add "$REMOTE_SOURCE"
    fi
  fi

  codex plugin add "$PLUGIN_SELECTOR"
  plugin_installed || { echo "ERROR: Codex did not report $PLUGIN_SELECTOR as installed; legacy files were left untouched." >&2; exit 1; }
  echo "Verified $PLUGIN_SELECTOR. Removing any legacy registration only after verification."
  if ! remove_legacy; then
    echo "ERROR: legacy cleanup failed; removing the plugin again to prevent dual registration." >&2
    codex plugin remove "$PLUGIN_SELECTOR" >/dev/null 2>&1 || true
    exit 1
  fi
  "$PLUGIN_ROOT/scripts/doctor.sh" plugin
}

if ! command -v claude >/dev/null 2>&1; then
  echo "WARNING: 'claude' not found on PATH. Hooks remain fail-open until Claude Code is installed and signed in." >&2
fi

if [ "$MODE" = "legacy" ]; then install_legacy; else install_plugin; fi

echo
echo "Installation complete. MANDATORY: start a new Codex session, run /hooks, and trust all three Claude Fusion hooks."
