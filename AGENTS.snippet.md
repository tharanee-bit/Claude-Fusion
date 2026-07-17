# Claude Fusion (historical manual snippet; not recommended)

Do not append this section to shared `AGENTS.md` or `CLAUDE.md` files for a normal installation.
Claude Fusion's injected context and bundled `claude-fusion-auto` skill are authoritative, avoid
always-on token cost, and preserve Claude Code `--safe-mode` isolation. This file remains only for
compatibility with older manual-install documentation.

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
