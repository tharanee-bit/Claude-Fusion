#!/usr/bin/env bash
# Remove Claude Fusion plugin and legacy installs. The marketplace remains configured unless the
# caller explicitly requests --purge-marketplace.
set -euo pipefail

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
HOOKS_FILE="$CODEX_DIR/hooks.json"
MARKETPLACE_NAME=claude-fusion
PLUGIN_SELECTOR=claude-fusion@claude-fusion
PURGE=0

case "${1:-}" in
  "") ;;
  --purge-marketplace) PURGE=1;;
  -h|--help) echo "Usage: ./uninstall.sh [--purge-marketplace]"; exit 0;;
  *) echo "Usage: ./uninstall.sh [--purge-marketplace]" >&2; exit 2;;
esac
[ "$#" -le 1 ] || { echo "Usage: ./uninstall.sh [--purge-marketplace]" >&2; exit 2; }

PY="$(command -v python3 2>/dev/null || true)"
[ -n "$PY" ] || { echo "ERROR: python3 is required." >&2; exit 1; }

if command -v codex >/dev/null 2>&1; then
  if codex plugin list --json 2>/dev/null | "$PY" -c '
import json,sys
try: data=json.load(sys.stdin)
except Exception: raise SystemExit(1)
raise SystemExit(0 if any(x.get("pluginId")=="claude-fusion@claude-fusion" and x.get("installed") for x in data.get("installed",[])) else 1)
' 2>/dev/null; then
    codex plugin remove "$PLUGIN_SELECTOR"
  else
    echo "No installed $PLUGIN_SELECTOR detected."
  fi
else
  echo "WARNING: codex is not on PATH; plugin configuration could not be removed." >&2
fi

if [ -f "$HOOKS_FILE" ]; then
  CF_HOOKS_FILE="$HOOKS_FILE" "$PY" - <<'PY'
import json, os, shutil, sys, tempfile
path = os.path.realpath(os.environ["CF_HOOKS_FILE"])
try: data = json.load(open(path))
except Exception as exc:
    print(f"WARNING: {path} is not valid JSON ({exc}); leaving it untouched.", file=sys.stderr)
    print("Legacy hook files were also left in place to avoid dangling registrations.", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(data, dict):
    print(f"WARNING: {path} is not a JSON object; leaving it untouched.", file=sys.stderr)
    print("Legacy hook files were also left in place to avoid dangling registrations.", file=sys.stderr)
    raise SystemExit(2)
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
if not removed:
    print("No legacy Claude Fusion registrations found in hooks.json.")
    raise SystemExit(0)
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

rm -f "$CODEX_DIR/hooks/claude-fusion-common.sh" "$CODEX_DIR/hooks/claude-fusion-userprompt.sh" \
  "$CODEX_DIR/hooks/claude-fusion-subagent-stop.sh" "$CODEX_DIR/hooks/claude-fusion-stop.sh"
rm -f "$CODEX_DIR/skills/claude-fusion-auto/SKILL.md"
rmdir "$CODEX_DIR/skills/claude-fusion-auto" 2>/dev/null || true

if [ "$PURGE" -eq 1 ]; then
  if command -v codex >/dev/null 2>&1 && codex plugin marketplace list --json 2>/dev/null | "$PY" -c '
import json,sys
try: data=json.load(sys.stdin)
except Exception: raise SystemExit(1)
raise SystemExit(0 if any(x.get("name")=="claude-fusion" for x in data.get("marketplaces",[])) else 1)
' 2>/dev/null; then
    codex plugin marketplace remove "$MARKETPLACE_NAME"
  else
    echo "Claude Fusion marketplace is not configured."
  fi
else
  echo "Marketplace '$MARKETPLACE_NAME' was left configured (use --purge-marketplace to remove it)."
fi

echo "Claude Fusion plugin and legacy files removed. Restart Codex to apply."
