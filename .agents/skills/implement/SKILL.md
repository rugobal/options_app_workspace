---
name: implement
description: "Implement specs or tickets using repository instructions, targeted tests, and a summary saved to the ticket."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

## 1. Read the repository instructions

Before planning implementation, editing code, or running checks, read the
applicable `AGENTS.md` and `CLAUDE.md` files at the workspace root, in each
affected repository, and in directories governing the files being changed.
Follow their relevant documentation pointers. If two instruction paths resolve
to the same file, read it once. For work across repositories, check each
repository's rules separately.

Identify the existing ticket and its tracking system from the user's reference
and repository instructions. Read `docs/agents/issue-tracker.md` when present and
use that tracker's configured workflow for ticket operations.

Explicit user instructions take precedence over repository and skill defaults.
Repository-specific rules constrain every step below and any invoked skills,
including testing, builds, branching, review, and commits.

## 2. Select targeted validation

In a brief progress update, name the instruction files that apply and the
targeted checks you will run.

Choose individual test cases, test files, or narrowly scoped integration tests
covering the changed behavior and directly affected paths. Follow repository
rules for test level, relevant type checks, and platform or build restrictions.

Full unit, integration, or repository-wide test suites require an explicit user
request for that run. A general request to implement, run checks, review, or
commit does not authorize a full suite. This restriction also applies to final
verification and other skills invoked during the work.

## 3. Implement with TDD

Use /tdd where applicable, at pre-agreed seams. Run the selected tests through
red and green. Repeat relevant tests or type checks when code changes, review
fixes, or failures justify it. Expand to additional named tests only to cover an
affected behavior or investigate a concrete failure; keep validation targeted.

## 4. Review

Once implementation and targeted checks are complete, use /code-review. Pass
the applicable repository instructions and testing and commit limits to the
reviewers. Review the task's uncommitted changes against the starting commit,
including staged, unstaged, and newly added files.
Address findings and rerun the targeted checks affected by each fix.

## 5. Prepare the implementation summary

Leave completed changes uncommitted for the user. Create commits only when the
user explicitly requests committing this task's changes; an implementation
request alone does not authorize commits. This limit applies throughout the
workflow, including invoked skills and sub-agents.

Write a self-contained summary in plain English for someone who has not read the
conversation. Scale its detail to the change, covering:

- **Outcome:** what was implemented, the problem it solves, and how it extends
  existing behavior.
- **Flow:** a short execution flow or diagram when it helps explain how the
  pieces work together.
- **Behavior changes:** the main user-visible and technical changes, with
  concrete examples for important rules or edge cases.
- **Main files and purpose:** a table of file paths, what changed, and why each
  file matters. Identify new files, group by repository or component when useful,
  and summarize repetitive caller changes together.
- **Validation:** the targeted checks actually run and their results, meaningful
  red/green evidence where applicable, review outcomes, and any validation limits.
- **Remaining work:** incomplete acceptance criteria, known limitations, and
  configuration, deployment, or dependent-ticket work still outstanding. State
  the actual completion and commit status.

Ground the summary in the final changes and observed results. Link relevant
files and documentation so the user can inspect the implementation.

## 6. Save the summary to the ticket and hand off

Save the same summary to the existing ticket's tracking system before the final
response, using the workflow identified in step 1:

| Tracking system | Where to store the summary |
| --- | --- |
| GitHub, Linear, Jira, or another hosted tracker | An implementation-summary comment or equivalent completion note on the existing ticket. |
| Markdown or another file-based tracker | An `Implementation summary` section in the existing ticket file, following its format. |

Preserve the ticket's specification, acceptance criteria, status, and unrelated
content. Recording the summary does not authorize creating or closing tickets.
For one ticket spanning repositories, store the combined summary on that ticket.
For multiple implemented tickets, record the relevant summary on each; parent
and dependent tickets are not additional destinations unless requested.

Keep the chat and stored summaries consistent, adapting formatting and file
links to the destination. Use repository-relative paths for unpublished changes;
do not invent remote code links or commit/push changes to make links available.

Verify the saved content and retain its comment URL, ticket link, or file path.
Before retrying an uncertain write, check whether the summary was already saved
to avoid duplicate comments. Update the summary for this implementation when
revising it, preserving other contributors' notes.

If saving remains blocked, save the completed summary in a local Markdown file
and report its path and the specific blocker; distinguish this fallback from a
successful tracker update. If there is no existing ticket, return the summary
without creating one unless the user requests it.

Return the full implementation summary in the final response and link to where
it was saved, so the user can read it directly in chat and find it on the ticket.
