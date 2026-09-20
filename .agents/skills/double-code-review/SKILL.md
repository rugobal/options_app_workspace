---
name: double-code-review
description: "Review a set of unpushed commits using the code-review skill, fix the routine findings, do a second code-review to catch material deviations or new minor issues, then squash the fixes into a single review commit. Use when the user wants to review and fix unpushed commits, typically after implement-tasks."
---

Perform a two-pass code review (double review) on a set of unpushed commits, fixing routine findings automatically and verifying them.

This skill delegates to the `code-review` skill. Reuse the parts it owns: the standards sources and smell baseline (code-review step 3), the two parallel sub-agent briefs (step 4), and the Standards/Spec separation. Keep the two axes separate throughout — never rerank a finding across axes.

A finding is **material** when it changes observable behaviour, business logic, public contracts, architecture, data handling, acceptance criteria, or contradicts the task specification. Every other finding is **routine**.

## Asking the user

Whenever this skill needs the user to decide or answer a question, check whether the `ask_telegram` tool is available. If it is, **ALWAYS use `ask_telegram`** (with clear options when applicable) and wait for the answer through the tool, so the user can respond remotely. If `ask_telegram` is not available, try `rpiv-ask-user-question`; if that is not available, fall back to `ask_user_question` or terminal prompts.

Write like you are talking to a human, not a technical person (don't use code language). Use business domain terms (read `domain.md` in each repository), plain language, clear and concise, and avoid unnecessary verbosity. This is the single rule for every user-facing prompt in this skill.

## Steps

### 0. Select commits

Check for unpushed commits on the current branch in every repository in the project (`git log origin/$(git branch --show-current)..HEAD --oneline`).

- 5 or fewer: select all of them.
- More than 5: use the asking rule to ask which commits to review.

Record the selected commit hashes and the first line of each message. Determine the **fixed point** once per affected repository: the commit just before the oldest selected commit in that repository.

### 1. First-pass review

Dispatch the Standards and Spec sub-agents in parallel with the briefs from `code-review` step 4, pasting the standards sources and smell baseline from step 3 into the Standards brief. The Spec brief takes the task documents named by the selected commits and their source specification as the spec, in place of code-review's issue-tracker discovery.

Wait for both sub-agents to finish. Report a one-line completion status to the user, but hold the findings for the final report.

### 2. Fix and commit

Fix the **routine** findings from the first pass. For any **material** finding, do not fix it: notify the user with the asking rule and await instruction, preserving the current work.

When a fix needs a user decision, use the asking rule. Verify with the focused tests for the affected acceptance criteria only; never run the full test suite. Re-run until they pass.

Commit the fixes as one review commit per affected repository. Its first line MUST state that the changes come from a code review and list the original commits, for example:

`Fix code review issues for Task 1 (e0ec516) and Task 2 (e4e480d)`

Take the logical names (like "Task 1") and hashes from the original commits; put the fix details in the body. If the first pass produced no fixes, make no commit here.

### 3. Second-pass review

Dispatch the second pass exactly as step 1, using the SAME fixed point per repository, so each diff covers the original commits plus the fixes. Because this skill typically follows `implement-tasks`, the Spec review must check the implementation against the task details and specifications and watch for introduced business-logic deviations.

- **Routine findings only:** fix them and verify with the focused tests for the affected acceptance criteria only (never the full test suite), re-running until they pass. Then squash these fixes into that repository's step-2 review commit, preserving its first line and adding the second-pass details to the body. If step 2 produced no review commit, create one with the same first-line format.
- **Material findings:** do not fix them. Notify the user with the asking rule and await instruction.

## Final report

Do not use code language. Write to a human, not a technical person: business domain terms, plain language, clear and concise.

Present the complete history of both passes: the findings and fixes of the first pass, then those of the second pass, keeping Standards and Spec separate. Omit the second pass's fixes when material findings prevented them.

Close with a short bullet summary and a conclusion: state plainly whether everything is complete and ready to push, or that material findings need manual correction.