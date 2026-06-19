# Claude Fusion (optional AGENTS.md guidance)

Append this section to `~/.codex/AGENTS.md` (global) or a project `AGENTS.md` if you want the
synthesis guidance always present, independent of the per-prompt injection. It is optional: the
`claude-fusion-userprompt.sh` hook already injects a self-contained preamble on every consult, and
the `claude-fusion-auto` skill carries the same process.

---

## Claude Fusion

This environment runs **Claude Fusion**: on non-trivial coding prompts, Claude Code is consulted
read-only and its analysis is injected as **AUTOMATIC CLAUDE FUSION CONTEXT**. After a complex,
file-changing task, Claude reviews the `git diff` and may return an **AUTOMATIC CLAUDE FUSION -
POST-DIFF REVIEW**.

When such a block appears:
- Form your own plan first, then reconcile with Claude's: note consensus, disagreements,
  Claude-only insights, and your own concerns. You remain the final judge.
- For a post-diff review, address every serious issue (correctness, security, data-loss,
  concurrency, broken tests) or justify why it is not a real problem.
- End with a short Claude Fusion summary (what Claude said, what you accepted/rejected and why,
  files changed, tests run, remaining risks).
