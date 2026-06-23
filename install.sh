#!/usr/bin/env bash
# Claude Fusion installer.
# Copies the hook scripts + skill into ~/.codex and merges the UserPromptSubmit + Stop hooks into
# ~/.codex/hooks.json non-destructively and idempotently. Honors CODEX_HOME. Requires python3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
HOOKS_DIR="$CODEX_DIR/hooks"
SKILLS_DIR="$CODEX_DIR/skills"
HOOKS_FILE="$CODEX_DIR/hooks.json"
CONFIG_FILE="$CODEX_DIR/config.toml"
HOOK_TIMEOUT=660   # registration timeout (seconds); must exceed the hook's internal CLAUDE_FUSION_TIMEOUT

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "ERROR: python3 is required (used to merge hooks.json)." >&2; exit 1; }

if ! command -v claude >/dev/null 2>&1; then
  echo "WARNING: 'claude' not found on PATH. Install Claude Code and sign in." >&2
  echo "         Installing the hooks anyway; they will silently skip until claude is available." >&2
fi

mkdir -p "$HOOKS_DIR" "$SKILLS_DIR/claude-fusion-auto"
install -m 0755 "$HERE/hooks/claude-fusion-userprompt.sh" "$HOOKS_DIR/claude-fusion-userprompt.sh"
install -m 0755 "$HERE/hooks/claude-fusion-stop.sh"        "$HOOKS_DIR/claude-fusion-stop.sh"
install -m 0644 "$HERE/skills/claude-fusion-auto/SKILL.md" "$SKILLS_DIR/claude-fusion-auto/SKILL.md"
echo "Installed hooks + skill into $CODEX_DIR"

CF_UPS="$HOOKS_DIR/claude-fusion-userprompt.sh" \
CF_STOP="$HOOKS_DIR/claude-fusion-stop.sh" \
CF_HOOKS_FILE="$HOOKS_FILE" \
CF_CONFIG="$CONFIG_FILE" \
CF_TIMEOUT="$HOOK_TIMEOUT" "$PY" - <<'PY'
import json, os, sys, shutil, tempfile

hooks_file = os.environ["CF_HOOKS_FILE"]
ups, stop = os.environ["CF_UPS"], os.environ["CF_STOP"]
HOOK_TIMEOUT = int(os.environ["CF_TIMEOUT"])

orig_text = None
data = {}
if os.path.exists(hooks_file):
    try:
        with open(hooks_file) as f:
            orig_text = f.read()
        data = json.loads(orig_text)
    except Exception as e:
        print(f"ERROR: {hooks_file} is not valid JSON ({e}); aborting so it isn't clobbered.", file=sys.stderr)
        sys.exit(1)

if not isinstance(data, dict):
    print("ERROR: hooks.json is not a JSON object; aborting.", file=sys.stderr); sys.exit(1)

# Codex auto-loads the wrapped {"hooks": {EVENT: [...]}} form. Preserve an existing shape if present,
# otherwise create the wrapped form (verified to load).
EVENTS = ("UserPromptSubmit","Stop","SessionStart","PreToolUse","PostToolUse",
          "PermissionRequest","PreCompact","PostCompact","SubagentStart","SubagentStop")
if isinstance(data.get("hooks"), dict):
    container = data["hooks"]                 # existing wrapped
elif any(k in data for k in EVENTS):
    container = data                          # existing bare
else:
    data["hooks"] = {}                        # fresh -> wrapped
    container = data["hooks"]

def norm(cmd):
    # Compare commands by resolved path so a manually merged "$HOME/..." entry is recognized as the
    # same hook as install.sh's expanded absolute path (no duplicate registration at the manual seam).
    return os.path.normpath(os.path.expanduser(os.path.expandvars(cmd or "")))

def ensure(event, command):
    arr = container.setdefault(event, [])
    target = norm(command)
    for grp in arr:
        for h in grp.get("hooks", []):
            if norm(h.get("command")) == target:
                changed = False                                      # already present; converge on upgrade
                if h.get("type") != "command": h["type"] = "command"; changed = True
                if h.get("timeout") != HOOK_TIMEOUT: h["timeout"] = HOOK_TIMEOUT; changed = True
                return changed
    arr.append({"hooks": [{"type": "command", "command": command, "timeout": HOOK_TIMEOUT}]})
    return True

changed_ups = ensure("UserPromptSubmit", ups)
changed_stop = ensure("Stop", stop)

if not (changed_ups or changed_stop):
    print("hooks.json already has the Claude Fusion hooks; nothing to change.")
else:
    # Back up the exact pre-change file, then swap atomically (temp + os.replace) so an interrupted
    # write can never leave hooks.json truncated. Only touch the file when something actually changes.
    if orig_text is not None:
        shutil.copy2(hooks_file, hooks_file + ".claude-fusion.bak")
    d_name = os.path.dirname(hooks_file) or "."
    os.makedirs(d_name, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d_name, prefix=".hooks.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, hooks_file)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
    print(f"hooks.json merged (UserPromptSubmit changed: {changed_ups}, Stop changed: {changed_stop})")

# Coexistence warning: configured hooks in config.toml plus hooks.json may double-register.
cfg = os.environ.get("CF_CONFIG", "")
if cfg and os.path.exists(cfg):
    try:
        import tomllib
        with open(cfg, "rb") as f:
            hooks_cfg = tomllib.load(f).get("hooks")
            if isinstance(hooks_cfg, dict) and any(event in hooks_cfg for event in EVENTS):
                print("WARNING: ~/.codex/config.toml already defines a [hooks] table. You may end up "
                      "with duplicate hooks; remove the config.toml [hooks] entries or the hooks.json ones.",
                      file=sys.stderr)
    except Exception:
        pass
PY

echo
echo "Done. NEXT STEP (required): start Codex, then run /hooks and TRUST the two Claude Fusion hooks."
echo "Codex will not run a hook until you review it. You'll see 'N hooks need review' until you do."
