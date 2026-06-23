# Claude Fusion

**Automatic peer review for OpenAI Codex, powered by your local Claude Code.**

Claude Fusion makes [OpenAI Codex](https://github.com/openai/codex) automatically consult
[Claude Code](https://claude.com/claude-code) as an independent second opinion on non-trivial coding
tasks - *without* a slash command, and *without* you typing anything. It is the mirror image of
[Codex Fusion](https://github.com/tharanee-bit/Codex-Fusion): there Claude is primary and Codex advises; here **Codex is
primary and Claude advises**. It uses Codex **hooks**:

- **Before** Codex plans or edits, a `UserPromptSubmit` hook runs Claude **read-only** over your
  repo and injects Claude's independent analysis into Codex's context. Codex then reconciles its own
  plan with Claude's (consensus / disagreements / Claude-only insights) before touching code.
- **After** Codex finishes a complex, file-changing task, a `Stop` hook runs Claude **read-only**
  over the resulting `git diff`. If Claude flags serious problems (correctness, security, data-loss,
  concurrency, broken tests), Codex is asked to address them before finalizing.

Codex stays the editor and the final judge. Claude only advises and reviews - it is always
**read-only** and never edits your files.

> **No credential games.** Claude Fusion shells out to the official `claude` CLI that you are
> already logged into. It does not use browser cookies, scraping, private APIs, or token extraction.

---

## How it works

```
                       you type a prompt to Codex
                                  |
                                  v
   UserPromptSubmit hook -- gate? --no--> (silent, Codex proceeds normally)
        | yes (non-trivial)
        v
   claude -p  (read-only, plan mode)  --> analysis injected as additionalContext
        |
        v
   Codex synthesizes Codex + Claude, then edits
        |
        v
   Stop hook -- task was complex AND git diff non-empty? --no--> (Codex finishes)
        | yes
        v
   claude -p  (read-only) over the diff
        |
        +-- verdict PASS         --> Codex finishes
        +-- verdict ISSUES_FOUND --> Codex must address them first
                                     (decision:block -> Codex continues with the review as a new prompt)
```

The two hooks coordinate through a small per-session marker file in
`${TMPDIR:-/tmp}/claude-fusion-state-<uid>/`, so the Stop review only fires for tasks the UserPromptSubmit
gate already judged complex.

## Requirements

- **OpenAI Codex** CLI (`codex`) with the `hooks` feature (stable in recent versions; verified on
  `codex-cli 0.130.0`).
- **Claude Code** (`claude`) installed and signed in.
- **python3**, **git**, **bash**, **GNU grep** (the gate uses `grep -z`), and the usual text
  utilities (`timeout`, `base64`, `sed`, `head`, `wc`, `tr`). `jq` is *not* required - JSON is
  handled with python3.

Tested on Linux / WSL2.

## Install

```bash
git clone https://github.com/tharanee-bit/Claude-Fusion.git
cd Claude-Fusion
./install.sh
```

`install.sh` copies the hook scripts and skill into `~/.codex/` and **merges** the two hooks into
`~/.codex/hooks.json` non-destructively (it backs the file up to `hooks.json.claude-fusion.bak`
first, and is idempotent - re-running won't duplicate entries). It respects `CODEX_HOME` if you set
it.

### Required: trust the hooks

Codex will **not run a hook until you review and trust it**. After installing:

1. Start `codex`.
2. You'll see a banner like `2 hooks need review before they can run`.
3. Run `/hooks` and **trust** the two Claude Fusion hooks.

This is a one-time step (per hook). If you later change a hook script, Codex may ask you to review it
again.

### Manual install

Copy `hooks/*.sh` into `~/.codex/hooks/` (and `chmod +x` them), copy `skills/claude-fusion-auto/`
into `~/.codex/skills/`, then merge `hooks.snippet.json` into `~/.codex/hooks.json`. (Alternatively,
append `config-hooks.snippet.toml` to `~/.codex/config.toml` - both load paths work; don't use both.)
The snippets reference the hook scripts as `$HOME/.codex/hooks/...`; if your Codex build does not
expand `$HOME` in a hook command, substitute your absolute home path. (`install.sh` always writes
absolute paths, so this caveat only applies to a manual merge.)

## Configuration

| Knob | Default | Effect |
|---|---|---|
| `[no-claude]` in your prompt | - | Skips Claude entirely for that prompt. |
| `CLAUDE_FUSION_MODEL` | `opus` | Claude model. Defaults to the strongest (latest Opus). |
| `CLAUDE_FUSION_EFFORT` | `xhigh` | Reasoning effort (`low` / `medium` / `high` / `xhigh` / `max`). |
| `CLAUDE_FUSION_DEPTH` | `workflow` | `workflow` = ask Claude for a deeper read-only analysis; `single` = one-shot analysis (faster). With the default safe mode, workflow stays isolated. |
| `CLAUDE_FUSION_TOOLS` | `readonly` | `readonly` = Claude can read/grep/glob + read-only git to explore the repo; `none` = `--tools ""` (analyze only the injected prompt + git status/diff). |
| `CLAUDE_FUSION_SAFE_MODE` | `1` | `1` = run Claude with `--safe-mode`, preventing `CLAUDE.md`, memory, skills, plugins, workflows, MCP servers, and custom agents from leaking into the consult. If your Claude Code build does not support `--safe-mode`, the hook skips rather than falling back to custom context. `0` = allow local Claude customizations, including ultracode/dynamic workflows. |
| `CLAUDE_FUSION_TIMEOUT` | `600` (workflow) / `300` (single) | Internal timeout (seconds) around the `claude` call. |
| `CLAUDE_FUSION_DEBUG=1` | off | Logs gate/flow to `${TMPDIR:-/tmp}/claude-fusion-state-<uid>/debug.log`. |

> **Strongest model, isolated by default.** Claude Fusion runs on the best Claude model at `xhigh`
> and, by default, uses Claude Code `--safe-mode` so the consult stays focused on the injected task
> and repository context rather than your personal Claude setup. **This costs latency:** a complex
> prompt waits for Claude (often 1-3 minutes, sometimes longer in `workflow` mode) before Codex
> responds. To deliberately trade isolation for local Claude workflows, set
> `CLAUDE_FUSION_SAFE_MODE=0`. To trade quality for speed, set `CLAUDE_FUSION_DEPTH=single`, lower
> `CLAUDE_FUSION_EFFORT`, or use `[no-claude]` to skip a given prompt. The hook-registration timeout
> in `hooks.json` (660s) sits above the internal
> timeout; if your Codex build caps hook timeouts lower and `workflow` analyses get killed, use
> `single` mode or a smaller `CLAUDE_FUSION_TIMEOUT`.

### The trigger gate

The `UserPromptSubmit` hook uses an **aggressive** gate: it consults Claude on most substantive
prompts and only skips when a prompt is clearly trivial or conversational - `[no-claude]`, fewer than
3 words, a typo/rename/format/lint/comment edit, a greeting, or a short pure question with no coding
verb. To make it conservative instead, edit the gate block in `hooks/claude-fusion-userprompt.sh`.

## Safety model

- Claude always runs `--permission-mode plan` (it cannot edit files), `--no-session-persistence`,
  and, by default, `--safe-mode` plus read-only tools. Safe mode prevents Claude Code from loading
  `CLAUDE.md`, memory, skills, plugins, workflows, MCP servers, and custom agents into the automatic
  consult. The prompt also tells Claude not to inspect credentials, `.env`, tokens, keychains, shell
  history, or auth files.
- Both hooks **never block** Codex on the no-action path - they always exit 0. If Claude is missing,
  not logged in, times out, or errors, the hook silently skips. A `timeout` wrapper bounds every
  `claude` call so a hook can never hang Codex.
- The `Stop` hook only ever asks Codex to continue (`decision: block`) when Claude explicitly returns
  `CLAUDE_REVIEW_VERDICT: ISSUES_FOUND`, and it is loop-safe via `stop_hook_active` - it reviews at
  most once per task.
- **Loop-safe with Codex Fusion.** If you also run [Codex Fusion](https://github.com/tharanee-bit/Codex-Fusion) (Claude ->
  Codex), Claude Fusion exports `CLAUDE_FUSION_ACTIVE=1` when it calls Claude and short-circuits at
  the top of every hook when that variable is set, so the inherited environment breaks any
  claude<->codex hook loop. (Independently, `codex exec` - which Codex Fusion uses - does not fire
  Codex lifecycle hooks.)

## Test it

```bash
# Triggers Claude (you'll see "AUTOMATIC CLAUDE FUSION CONTEXT" injected into Codex):
#   Refactor the auth middleware to eliminate the token-refresh race condition.
# Skips (trivial):       Fix the typo in the README heading.
# Skips (escape hatch):  Refactor the payment retry logic [no-claude]
```

You can also exercise the hook directly without Codex:

```bash
echo '{"prompt":"Refactor the auth module to fix a race condition","cwd":"'"$PWD"'","session_id":"t1"}' \
  | CLAUDE_FUSION_DEBUG=1 CLAUDE_FUSION_DEPTH=single ~/.codex/hooks/claude-fusion-userprompt.sh
```

(That prints the `{"hookSpecificOutput":{...}}` JSON Codex consumes. Use `CLAUDE_FUSION_DEPTH=single`
for a faster check.)

## Uninstall

```bash
./uninstall.sh
```

Removes the two hook entries from `hooks.json` (leaving a `*.claude-fusion.bak` backup) and deletes
the installed hook scripts and skill. Your other hooks and settings are untouched.

## Layout

```
hooks/claude-fusion-userprompt.sh   # Codex UserPromptSubmit hook (pre-edit analysis)
hooks/claude-fusion-stop.sh         # Codex Stop hook (post-diff review)
skills/claude-fusion-auto/SKILL.md  # how Codex synthesizes Codex + Claude
hooks.snippet.json                  # hooks block to merge into ~/.codex/hooks.json (manual install)
config-hooks.snippet.toml           # alternative: [hooks] tables for ~/.codex/config.toml
AGENTS.snippet.md                   # optional always-on guidance for ~/.codex/AGENTS.md
install.sh / uninstall.sh           # idempotent installer / remover
```

## How the Codex hook contract was verified

Codex's hook system turned out to be a close port of Claude Code's, confirmed against
`codex-cli 0.130.0`:

- `~/.codex/hooks.json` (the wrapped `{"hooks":{"UserPromptSubmit":[...],"Stop":[...]}}` form)
  auto-loads; inline `[hooks]` tables in `config.toml` also work.
- Hook **input** (stdin JSON) uses snake_case fields - `session_id`, `cwd`, `prompt`,
  `hook_event_name`, `stop_hook_active`, ... - identical to Claude Code.
- Hook **output** uses `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit",
  "additionalContext":"..."}}` to inject context and `{"decision":"block","reason":"..."}` to
  intervene - identical to Claude Code. For the `Stop` event, `decision:block` makes Codex *continue*
  using `reason` as a new prompt.
- Codex gates hooks behind explicit `/hooks` review/trust before they run.
- `codex exec` does not fire `UserPromptSubmit`/`Stop` hooks; they fire in interactive `codex`
  sessions (which is exactly when you want a second opinion).

## License

[MIT](LICENSE)
