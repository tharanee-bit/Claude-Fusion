---
name: claude-fusion-auto
description: "Synthesize Codex's own coding plan with the independent Claude analysis injected by Claude Fusion. Use whenever an 'AUTOMATIC CLAUDE FUSION CONTEXT' or 'AUTOMATIC CLAUDE FUSION - POST-DIFF REVIEW' block is present: complex coding tasks, architecture, debugging, refactors, migrations, security-sensitive changes, API design, and substantial code review. The user does not need to name this skill."
---

# Claude Fusion - automatic synthesis

When the conversation contains **AUTOMATIC CLAUDE FUSION CONTEXT** (injected by the
`claude-fusion-userprompt.sh` Codex hook), treat Claude as an independent peer reviewer whose
analysis you must reconcile with your own **before making any edits**.

## Process
1. Form your own plan first - do not anchor on Claude.
2. Compare against Claude's analysis and explicitly identify:
   - **Consensus** - where you and Claude agree.
   - **Disagreements** - where you differ, and which side you choose and why.
   - **Claude-only insights** - useful points Claude raised that you missed.
   - **Codex-only concerns** - risks/considerations Claude missed.
   - **Final decision** - your chosen approach.
3. You remain the final judge. Do **not** blindly obey Claude; reject its suggestions when you have
   a sound reason, and say so.
4. Prefer **minimal, testable** changes.
5. After editing, run the relevant **tests / lint / typecheck** for the project.

## Post-diff review (Stop hook)
If a **POST-DIFF REVIEW** from Claude appears, address every serious issue (correctness, security,
data-loss, concurrency, broken tests) before finalizing, or explicitly justify why each is not a
real problem.

## Required final summary
End your response with a short **Claude Fusion summary**:
- Whether Claude was consulted automatically.
- What Claude suggested (key points).
- What you accepted vs. rejected, and why.
- Files changed.
- Tests / checks run and their result.
- Remaining risks or follow-ups.
