#!/usr/bin/env bash
# Claude Fusion uninstaller.
# Removes the Claude Fusion hook entries from ~/.codex/hooks.json (backing it up first) and deletes
# the installed hook scripts and skill. Other hooks/settings are left intact. Honors CODEX_HOME.
set -euo pipefail

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
HOOKS_FILE="$CODEX_DIR/hooks.json"
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "ERROR: python3 is required." >&2; exit 1; }

if [ -f "$HOOKS_FILE" ]; then
  CF_HOOKS_FILE="$HOOKS_FILE" "$PY" - <<'PY'
import json, os, shutil, sys, tempfile
s = os.environ["CF_HOOKS_FILE"]
try:
    with open(s) as f:
        d = json.load(f)
except Exception as e:
    print(f"WARNING: {s} is not valid JSON ({e}); leaving it untouched.", file=sys.stderr)
    sys.exit(0)
if not isinstance(d, dict):
    print(f"WARNING: {s} is not a JSON object; leaving it untouched.", file=sys.stderr)
    sys.exit(0)

container = d["hooks"] if isinstance(d.get("hooks"), dict) else d

removed = 0
def strip(event):
    global removed
    new = []
    for grp in container.get(event, []):
        hooks = grp.get("hooks", [])
        kept = [h for h in hooks if "claude-fusion" not in (h.get("command") or "")]
        removed += len(hooks) - len(kept)
        if kept:
            g = dict(grp); g["hooks"] = kept; new.append(g)
    if new:
        container[event] = new
    elif event in container:
        del container[event]

for e in ("UserPromptSubmit", "Stop"):
    strip(e)
# tidy: drop an emptied wrapped "hooks" object
if isinstance(d.get("hooks"), dict) and not d["hooks"]:
    del d["hooks"]

if removed == 0:
    print("No Claude Fusion hook entries found in hooks.json; nothing to remove.")
else:
    # Back up, then swap atomically so an interrupted write can't truncate the file.
    shutil.copy2(s, s + ".claude-fusion.bak")
    d_name = os.path.dirname(s) or "."
    fd, tmp = tempfile.mkstemp(dir=d_name, prefix=".hooks.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, s)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
    print("Removed Claude Fusion hook entries from hooks.json (backup: *.claude-fusion.bak)")
PY
fi

rm -f "$CODEX_DIR/hooks/claude-fusion-userprompt.sh" "$CODEX_DIR/hooks/claude-fusion-stop.sh"
rm -rf "$CODEX_DIR/skills/claude-fusion-auto"
echo "Removed hook scripts and skill. Restart Codex to apply."
