---
name: double-code-review
description: "Review a set of commits using the code-review skill, fix the issues, and do a second code-review to ensure no major deviations or new minor issues, then squash the fixes. Use when the user wants to review and fix unpushed commits, typically after implement-tasks."
---

Perform a two-pass code review (double review) on a set of unpushed commits, fixing issues automatically and verifying them.

This skill delegates internally to the `code-review` skill.

## Steps

### 0. Select Commits
Check for unpushed commits in the current branch across all repositories in the project (e.g. `git log origin/$(git branch --show-current)..HEAD --oneline`).
- If there are 5 or fewer unpushed commits, proceed to review all of them.
- If there are more than 5, use `ask_user_question` to ask the user which commits they want to review.

Note the commit hashes and the first lines of their messages.
Determine the **fixed point** (the commit just before the oldest selected commit) to use as the base for the reviews.

### 1. First Pass Code Review
Dispatch the first-pass review to parallel Standards and Spec sub-agents, exactly as the `code-review` skill instructs. Wait for both sub-agents to finish. Print a 1-line status update to the user acknowledging completion, but save the aggregated findings for the final report.

### 2. Fix and Commit
Fix the findings reported in the first pass. If any change requires user input upon review, check if the `ask_telegram` tool is available in your environment. If it is, **ALWAYS use the `ask_telegram` tool** to prompt the user (providing clear options when applicable), so they can respond remotely via Telegram. Wait for their answer through the tool before continuing. Do not use the standard `ask_user_question` tool or terminal prompts when `ask_telegram` is available. If `ask_telegram` is not available, try the `rpiv-ask-user-question` tool, and if not available, fall back to the standard `ask_user_question` tool or terminal prompts.
When verifying that the fixes are correct, never run the full test suite. Run only the focused, targeted tests required to verify the immediate acceptance criteria of the current task. If any test fails, fix it and re-run until all tests pass.
After all fixes are applied, commit the changes. The commit message's first line MUST clearly state that the changes are due to a code review and list the original commits.
Example format:
`Fix code review issues for Task 1 (e0ec516) and Task 2 (e4e480d)`
Extract the logical names (like "Task 1") and hashes from the original commits to construct this message. Add more details about the fixes in the commit body.

### 3. Second Pass Review
Dispatch the second-pass review to parallel Standards and Spec sub-agents, using the SAME fixed point from step 0 (so the diff covers the original commits plus your new fixes).
Because this skill is typically used after `implement-tasks`, pay special attention during the Spec review to ensure the implementation is correct according to the task details and specifications, and that no business logic deviations were introduced.

- **Minor findings only**: If the code does what is expected with no business logic deviations, fix any remaining minor findings and commit them. When verifying that the fixes are correct, never run the full test suite. Run only the focused, targeted tests required to verify the immediate acceptance criteria of the current task. If any test fails, fix it and re-run until all tests pass. **Squash** this new commit into the previous review commit (the one from step 2), conserving the initial first line and appending details.
- **Major findings**: If you find major deviations or worrying issues, **do not fix them**. Notify the user and await instruction. To notify the user use `ask_telegram` tool is available in your environment. If it is, **ALWAYS use the `ask_telegram` tool** to prompt the user (providing clear options when applicable). If `ask_telegram` is not available, try the `rpiv-ask-user-question` tool, and if not available, fall back to the standard `ask_user_question` tool or terminal prompts.

## Final Report Format
When providing your findings, don't use code language. Write it like you are talking to a human, not a technical person. Use business domain terms, plain language, clear and concise, and avoid unnecessary verbosity.

When concluding the skill, present the complete history of both passes providing the findings and fixes in the first refview, and the findings and fixes on the second review Omit the fixes for Review 2 if major findings prevented fixes:

And at the end provide brief summary of the whole process with bullet points and a conclusion: State clearly whether everything is completed and ready to be pushed, or alert the user that major findings require manual correction.

