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
- **Whenever a subagent finishes** under that gated parent turn, a `SubagentStop` hook reviews its
  capped final message and the filtered parent-turn diff when present. Research-only agents are
  included. Duplicate events are deduplicated and at most two unique subagents are reviewed by
  default; the main final-diff review still runs.

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
   claude -p  (read-only, JSON schema) --> analysis + optional questions injected as context
        |
        v
   Codex synthesizes Codex + Claude, then edits
        |
        +--> SubagentStop (up to 2 unique agents) --> PASS or continue that subagent
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

The three hooks coordinate through small session-plus-turn marker files in
`${TMPDIR:-/tmp}/claude-fusion-state-<uid>/`, so the Stop review only fires for tasks the UserPromptSubmit
gate already judged complex. The marker records the prompt-time `HEAD`, and the Stop hook diffs the
working tree against that commit, so work Codex commits mid-turn still gets reviewed. Each definitive
review also stores a hash of the reviewed diff (an unchanged diff is not re-reviewed by a later gated
prompt), and repeated transient review failures on the same diff stop after
`CLAUDE_FUSION_STOP_RETRY_LIMIT` attempts. Legacy session-only markers remain readable during
upgrades.

Claude Code clients that support `--output-format json` and `--json-schema` use validated JSON
envelopes for both analysis and review. Non-success envelopes, `is_error`, malformed JSON, and
missing or invalid `structured_output` are failed attempts. Older clients keep the two-attempt text
path. After two malformed structured attempts, Claude Fusion makes one final fixed-Opus text
attempt. Timeouts are never retried.

## Requirements

- **OpenAI Codex** CLI (`codex`) with hooks and plugins (verified on `codex-cli 0.142.0`).
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

The default installer adds or updates the `tharanee-bit/Claude-Fusion` marketplace through
`codex plugin marketplace`, installs `claude-fusion@claude-fusion`, verifies that Codex reports it
installed, and only then removes a legacy copy-and-merge installation. Any changed legacy
`hooks.json` is backed up first. It never edits Codex marketplace configuration directly and it
respects `CODEX_HOME`.

For development or compatibility:

```bash
./install.sh --local   # plugin from this checkout
./install.sh --legacy  # copy canonical hooks/skill and merge ~/.codex/hooks.json
```

Plugin registration and legacy registration must never be enabled at the same time. Each installer
path runs the bundled read-only doctor automatically.

### Required: trust the hooks

Codex will **not run a hook until you review and trust it**. After installing:

1. Start `codex`.
2. You'll see a banner that hooks need review.
3. Run `/hooks` and **trust all three** Claude Fusion hooks.

This is a one-time step (per hook). If you later change a hook script, Codex may ask you to review it
again.

### Manual install

Copy `plugins/claude-fusion/hooks/*.sh` into `~/.codex/hooks/` (and `chmod +x` the three event
scripts), copy `plugins/claude-fusion/skills/claude-fusion-auto/` into `~/.codex/skills/`, then
merge `hooks.snippet.json` into `~/.codex/hooks.json`. (Alternatively,
append `config-hooks.snippet.toml` to `~/.codex/config.toml` - both load paths work; don't use both.)
The snippets reference the hook scripts as `$HOME/.codex/hooks/...`; if your Codex build does not
expand `$HOME` in a hook command, substitute your absolute home path. (`install.sh` always writes
absolute paths in `--legacy` mode, so this caveat only applies to a manual merge.)

## Configuration

| Knob | Default | Effect |
|---|---|---|
| `[no-claude]` in your prompt | - | Skips Claude entirely for that prompt. |
| `CLAUDE_FUSION_MODEL` | `fable` | Primary Claude model. Defaults to the latest Fable alias; overrides affect only the first attempt. |
| `CLAUDE_FUSION_EFFORT` | `xhigh` | Primary reasoning effort (`low` / `medium` / `high` / `xhigh` / `max`); overrides affect only the first attempt. |
| `CLAUDE_FUSION_DEPTH` | `workflow` | `workflow` = ask Claude for a deeper read-only analysis; `single` = one-shot analysis (faster). With the default safe mode, workflow stays isolated. |
| `CLAUDE_FUSION_TOOLS` | `readonly` | `readonly` = Claude can read/grep/glob + read-only git to explore the repo; `none` = `--tools ""` (analyze only the injected prompt + git status/diff). |
| `CLAUDE_FUSION_SAFE_MODE` | `1` | `1` = run Claude with `--safe-mode`, preventing `CLAUDE.md`, memory, skills, plugins, workflows, MCP servers, and custom agents from leaking into the consult. If your Claude Code build does not support `--safe-mode`, the hook skips rather than falling back to custom context. `0` = allow local Claude customizations, including ultracode/dynamic workflows. |
| `CLAUDE_FUSION_CONTINUITY` | `0` | `1` = persist and resume only the UserPromptSubmit Claude session. Invalid saved sessions are discarded and retried fresh. Stop and SubagentStop reviews always remain fresh. |
| `CLAUDE_FUSION_SUBAGENT_REVIEW` | `1` | `0` disables SubagentStop review without disabling pre-prompt or final review. |
| `CLAUDE_FUSION_SUBAGENT_REVIEW_LIMIT` | `2` | Maximum unique subagent reviews atomically reserved per gated parent turn. |
| `CLAUDE_FUSION_TIMEOUT` | `600` (workflow) / `300` (single) | Internal timeout (seconds) around the `claude` call. |
| `CLAUDE_FUSION_STOP_RETRY_LIMIT` | `2` | Transient failed Stop-review attempts for an unchanged diff before skipping until the diff changes. |
| `CLAUDE_FUSION_EXCLUDE` | - | Extra space-separated globs to exclude from the status/diff sent to Claude, on top of the built-in sensitive-path denylist (globs containing spaces are unsupported). |
| `CLAUDE_FUSION_MAX_FILE_BYTES` | `409600` | Per-file size cap; changed files larger than this are dropped from the diff payload. |
| `CLAUDE_FUSION_DEBUG=1` | off | Logs gate/flow to `${TMPDIR:-/tmp}/claude-fusion-state-<uid>/debug.log`. |

> **Fable first, latest Opus fallback, isolated by default.** Claude Fusion first runs the latest
> Fable at `xhigh`. Structured-capable clients then try the latest Opus alias at `xhigh`, followed
> by one final Opus text attempt after malformed structured exhaustion. Older clients retain the
> original two-attempt Fable/Opus text path. The fallback is fixed even when the primary model or
> effort is overridden. Timeouts are not retried. By default, Claude Code `--safe-mode` keeps the consult
> focused on the injected task and repository context rather than your personal Claude setup.
> **This costs latency:** a complex prompt waits for Claude (often 1-3 minutes, sometimes longer in
> `workflow` mode) before Codex responds. To deliberately trade isolation for local Claude
> workflows, set
> `CLAUDE_FUSION_SAFE_MODE=0`. To trade quality for speed, set `CLAUDE_FUSION_DEPTH=single`, lower
> `CLAUDE_FUSION_EFFORT`, or use `[no-claude]` to skip a given prompt. The hook-registration timeout
> in `hooks.json` (660s) sits above the internal
> timeout; if your Codex build caps hook timeouts lower and `workflow` analyses get killed, use
> `single` mode or a smaller `CLAUDE_FUSION_TIMEOUT`.

### The trigger gate

The `UserPromptSubmit` hook uses an **aggressive** gate: it consults Claude on most substantive
prompts and only skips when a prompt is clearly trivial or conversational - `[no-claude]`, fewer than
3 words, a typo/rename/format/lint/comment edit, a greeting, or a short pure question with no coding
verb. To make it conservative instead, edit the gate block in
`plugins/claude-fusion/hooks/claude-fusion-userprompt.sh`.

## Safety model

- Claude always runs `--permission-mode plan` (it cannot edit files) and, by default,
  `--no-session-persistence`, `--safe-mode`, and read-only tools. The only persistence exception is
  explicit `CLAUDE_FUSION_CONTINUITY=1`, and that applies only to pre-prompt analysis, never either
  review hook. Safe mode prevents Claude Code from loading
  `CLAUDE.md`, memory, skills, plugins, workflows, MCP servers, and custom agents into the automatic
  consult. (The `--safe-mode` capability probe is cached per resolved `claude` binary, so it does not
  re-run `claude --help` on every prompt; updates invalidate the cache automatically.)
- **Sensitive paths never reach Claude in the harness payload.** The `git status` and diff the hooks
  embed are filtered at the source against a denylist of secret-bearing paths (env files, keys and
  certificates, `credentials*`/`secrets*`, shell history, `.netrc`/`.npmrc`/`.pypirc`, `auth.json`,
  SQLite databases, `.ssh`/`.aws`/`.gnupg` contents - extensible via `CLAUDE_FUSION_EXCLUDE`).
  Status lines for such paths are redacted; their diffs are dropped entirely, with a visible
  exclusion note. The prompt additionally tells Claude not to inspect credentials, but the guarantee
  is the source-level exclusion, not that instruction. Known limit: the filter is path-based, so if
  a turn renames a secret file to a non-denylisted name, the content appears under its new name.
- All three hooks **never block** Codex on the no-action/failure path - they always exit 0. If Claude is missing,
  not logged in, times out, or errors, the hook silently skips. A `timeout` wrapper bounds every
  `claude` call so a hook can never hang Codex.
- The `Stop` hook only ever asks Codex to continue (`decision: block`) when Claude explicitly returns
  `CLAUDE_REVIEW_VERDICT: ISSUES_FOUND`, and it is loop-safe via `stop_hook_active` - it reviews at
  most once per task.
- `SubagentStop` never reads `agent_transcript_path`. It sends only agent metadata, at most 12,000
  characters of `last_assistant_message`, and a size-capped diff that uses the same sensitive-path
  filtering. Unique-agent and slot directories are created atomically so duplicate events cannot
  consume a second slot. `ISSUES_FOUND` continues that subagent; failures remain fail-open.
- Claude may propose at most three structured `required` or `advisory` questions. Injected context
  and the bundled skill require Codex to inspect repo truth first, merge duplicates, ask all
  remaining required questions, and omit `autoResolutionMs` entirely. Without an interactive
  question tool, Codex ends the turn with the questions and waits.
- **Loop-safe with Codex Fusion.** If you also run [Codex Fusion](https://github.com/tharanee-bit/Codex-Fusion) (Claude ->
  Codex), Claude Fusion exports `CLAUDE_FUSION_ACTIVE=1` and `CODEX_FUSION_ACTIVE=1` when it calls
  Claude and short-circuits at the top of every hook when either variable is set, so the inherited
  environment breaks any claude<->codex hook loop. (Independently, `codex exec` - which Codex Fusion
  uses - does not fire Codex lifecycle hooks.)

## Test it

```bash
# Triggers Claude (you'll see "AUTOMATIC CLAUDE FUSION CONTEXT" injected into Codex):
#   Refactor the auth middleware to eliminate the token-refresh race condition.
# Skips (trivial):       Fix the typo in the README heading.
# Skips (escape hatch):  Refactor the payment retry logic [no-claude]
```

You can also exercise the hook directly without Codex:

```bash
echo '{"prompt":"Refactor the auth module to fix a race condition","cwd":"'"$PWD"'","session_id":"s1","turn_id":"t1"}' \
  | CLAUDE_FUSION_DEBUG=1 CLAUDE_FUSION_DEPTH=single \
    plugins/claude-fusion/hooks/claude-fusion-userprompt.sh
```

(That prints the `{"hookSpecificOutput":{...}}` JSON Codex consumes. Use `CLAUDE_FUSION_DEPTH=single`
for a faster check.)

## Health check

```bash
./doctor.sh
```

The self-contained doctor is read-only. It checks plugin and legacy detection, duplicate
registration, source/cache parity when discoverable, executable bits, dependency versions, Claude
capabilities, read-only flags, timeout ordering, state-directory safety, and manifest shape. It
always reports `/hooks` trust as the remaining mandatory human gate and never changes files.

`AGENTS.snippet.md` remains only as a historical/manual reference. Do not merge shared `AGENTS.md`
or `CLAUDE.md` instructions for Claude Fusion: the injected context and bundled
`claude-fusion-auto` skill are authoritative, preserving `--safe-mode` isolation.

## Uninstall

```bash
./uninstall.sh
./uninstall.sh --purge-marketplace  # also remove the configured marketplace
```

Removes plugin and legacy installations safely. The marketplace remains configured by default for
easy reinstallation; `--purge-marketplace` removes it through `codex plugin marketplace remove`.
Other hooks and settings are untouched, and changed `hooks.json` files are backed up.

## Layout

```
.agents/plugins/marketplace.json                    # repo marketplace named claude-fusion
plugins/claude-fusion/.codex-plugin/plugin.json     # v0.1.0 plugin manifest
plugins/claude-fusion/hooks/hooks.json              # default-discovered three-hook registration
plugins/claude-fusion/hooks/*.sh                    # canonical runtime
plugins/claude-fusion/skills/claude-fusion-auto/    # authoritative synthesis/question skill
plugins/claude-fusion/scripts/doctor.sh              # canonical read-only doctor
hooks/*.sh                                           # checkout compatibility wrappers
hooks.snippet.json / config-hooks.snippet.toml       # legacy manual registration snippets
doctor.sh / install.sh / uninstall.sh                # root operational entry points
tests/test_hooks.py                                  # fake-Claude/fake-Codex unit and migration suite
```

For a manual legacy install, copy the canonical common helper alongside all three event scripts;
the event scripts source it from their own directory and fail open if it is missing.

## How the Codex hook contract was verified

Codex's hook system turned out to be a close port of Claude Code's, confirmed against
`codex-cli 0.142.0`:

- `~/.codex/hooks.json` (the wrapped
  `{"hooks":{"UserPromptSubmit":[...],"SubagentStop":[...],"Stop":[...]}}` form)
  auto-loads; inline `[hooks]` tables in `config.toml` also work.
- Hook **input** (stdin JSON) uses snake_case fields including `session_id`, `turn_id`, `cwd`,
  `prompt`, `stop_hook_active`, `agent_id`, `agent_type`, `agent_transcript_path`, and
  `last_assistant_message`.
- Hook **output** uses `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit",
  "additionalContext":"..."}}` to inject model context, top-level `systemMessage` for user-facing
  warnings, and `{"decision":"block","reason":"..."}` to
  intervene - identical to Claude Code. For the `Stop` event, `decision:block` makes Codex *continue*
  using `reason` as a new prompt.
- Codex gates hooks behind explicit `/hooks` review/trust before they run.
- Plugin hook discovery expands `${PLUGIN_ROOT}` from `plugins/claude-fusion/hooks/hooks.json`.
- Codex command hooks are synchronous; Claude Fusion does not request asynchronous execution.
- `codex exec` does not fire these lifecycle hooks; they fire in interactive `codex`
  sessions (which is exactly when you want a second opinion).

## License

[MIT](LICENSE)
