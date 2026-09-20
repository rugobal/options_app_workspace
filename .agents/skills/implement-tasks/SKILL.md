---
name: implement-tasks
description: "Implement all or a requested number of pending tasks from a master implementation index by dispatching isolated agent sessions, respecting dependencies, and committing each completed task. Use when a user points to a task index and asks to implement its tasks, including requests without subagents."
---

# Implement Tasks

Act as the orchestrator. Every task is implemented in a fresh, isolated agent session given its specific task document. Your work is parsing, scheduling, dispatching, verification, Git integration, and index bookkeeping; delegate implementation and corrective code changes.

## 1. Parse and select

Read the referenced index and applicable `AGENTS.md` files. Resolve task and specification links relative to the index. Record the source specification's exact basename, including its extension, for commit messages.

Read the task table by column name. Rows with `[ ]` in **Implemented** are pending; `[x]` and `[X]` are complete. Extract each task's number, document path, dependencies from **Depends on**, and status. Resolve dependency references to task numbers.

For “all,” select every pending task. For “first N” or “next N,” select the first N pending rows in document order; completed rows do not count. Honor explicit task numbers or ranges instead when supplied. Freeze this selection for the run, and report when fewer than N pending tasks exist.

Read the selected task documents and check that their dependencies agree with the index. A prerequisite is met only when it is marked complete and its implementation is available on the integration base. Selected prerequisites can be completed earlier in this run. A missing prerequisite outside the selection is a blocker, not permission to expand scope or substitute another task.

When a task requires tests to be written or changed, look for `testing.md` in each corresponding repository. If the file exists, record its path; the implementation session must read it before writing tests and follow its testing conventions and commands. Continue without it when the repository has no `testing.md`.

Apply a human decision gate to missing documents, ambiguous specification names, dependency contradictions, cycles, and any inconsistency between the index, specification, task document, repository instructions, codebase, or observed behavior. Use judgment to distinguish small discrepancies from material deviations:

- A discrepancy is small when the intended result is still clear and resolving it does not change scope, observable behavior, public contracts, architecture, data handling, acceptance criteria, or the dependency plan. Resolve it, record the interpretation in the dispatch or final report, and continue.
- A deviation is material when more than one reasonable interpretation exists or the choice could change any of those outcomes. Pause the run before further implementation, dispatch, integration, commits, or index updates. Preserve existing work and ask the user to decide, presenting the evidence, the conflicting sources, and the concrete options with their consequences. Resume only after receiving that decision.

When pausing for a human decision or asking the user any clarifying question during the implementation, write like you are talking to a human, not a technical person (don't use code language). Use business domain terms, plain language, clear and concise, and avoid unnecessary verbosity. Check if the `ask_telegram` tool is available in your environment. If it is, **ALWAYS use the `ask_telegram` tool** to prompt the user (providing clear options when applicable), so they can respond remotely via Telegram. Wait for their answer through the tool before continuing. Do not use the standard `ask_user_question` tool or terminal prompts when `ask_telegram` is available. If `ask_telegram` is not available, try the `rpiv-ask-user-question` tool, and if not available, fall back to the standard `ask_user_question` tool or terminal prompts.

If an implementation session discovers a potential deviation, it must stop at a recoverable point and report it without choosing a direction. The orchestrator applies the materiality judgment. When material, notify other active sessions to stop at recoverable points and bring the decision to the user.

Completion criterion: every selected task has a known document, repository, specification basename, and dependency state; for tasks requiring test changes, any existing applicable `testing.md` paths are identified.

## 2. Establish isolation and ownership

Inspect Git status and record the integration branch and starting commit in each affected repository. Preserve unrelated changes and keep them out of task commits. Ensure sessions start from the intended integration state, including completed prerequisites, rather than a default branch that may be stale.

Use the environment's supported fresh-session mechanism. A session must have its own conversation context; another prompt in the current conversation is insufficient. Give each concurrent worker a separate checkout, normally a Git worktree, and its own branch so its uncommitted changes cannot overlap with another worker's files. Give a sequential worker the integration checkout itself: it works in the current working directory on the integration branch, with no worktree and no branch of its own. Create a worktree and branch only when two or more workers run concurrently. Use `agent/` branch names unless repository or user instructions specify otherwise.

Identify one integration owner for each dispatch. For a single task, this is you. For a parallel batch, the new batch orchestrator owns worker commits and integration within its checkout; you integrate its result into the original target. Only the integration owner updates the master index. Workers return changes and validation evidence without independently changing index checkboxes.

If the required fresh-session mechanism is unavailable, report that concrete limitation. Keep the isolation requirement intact instead of implementing the task in the current session.

## 3. Schedule and dispatch

Recompute the ready set after each integration: selected pending tasks whose prerequisites are complete and present on the integration base. Use document order to break ties.

- **One ready task:** start a fresh implementation session for that task and wait for its result.
- **Two or more independent ready tasks:** start one fresh orchestrator session for a batch of at most three tasks. Instruct it to spawn one fresh subagent per task, each in its own worktree and branch, then coordinate validation and merge their work. Each worker implements only its assigned task. Cap concurrent implementation subagents at three, or fewer if the environment's capacity requires it. Finish and integrate the batch before dispatching another batch.
- **User says “do not use subagents” or equivalent:** execute sequentially, one fresh individual session per task. Propagate this restriction to every session. Use a non-subagent session mechanism; do not substitute sequential subagents. Dependency readiness still applies.

Give every dispatch a self-contained brief containing:

- The exact task document path, task number, index path, and source specification path and basename.
- The assigned scope, user constraints, applicable repository instructions, and completed prerequisite context.
- The checkout/worktree path, branch, starting commit, and integration destination for each affected repository.
- For tasks requiring test changes, every existing applicable `testing.md` path and an explicit instruction to read it before writing tests.
- Required acceptance criteria and validation, the integration owner, and the commit-and-advance protocol below.
- The required documentation updates before commit: the task `.md` file must be updated with an implemented status, completed checklists, and an `## Implementation Verification` section with actual evidence; and the master index (e.g. `README.md`) must be updated to mark the task completed. All of this must be included in the single task commit alongside the code.
- The human decision gate: report potential deviations before implementing through them, and leave materiality decisions to the orchestrator.
- A request to return changed files, validation commands and results, remaining issues, and any branch or commit identifiers.

A parallel orchestrator's brief must explicitly request subagents, separate worktrees and branches, serial integration of completed workers, and deletion of only the branches created for this dispatch after successful integration. It coordinates implementation; workers make the code changes, including any fixes required by integration.

Completion criterion: every dispatched task has a unique implementation session and a traceable checkout; the concurrency and user override rules hold.

## 4. Commit and advance

Wait for the implementation session to finish successfully. Check its diff, acceptance criteria, and validation evidence. Session termination alone is not success. Apply the human decision gate before requesting corrections: routine defects return to the responsible session, while material deviations pause the run for the user's decision. Keep the task pending until it passes.

After the implementation and its required checks pass, but before committing, prepare the documentation updates. You must make **exactly one commit per task** that includes the implementation, the task `.md` document update, and the index update.

First, update the assigned task document to mark it completed and verified:
- Change its status from pending to implemented and verified, preserving the document's existing status style and adding the completion date when that style includes dates.
- Change every completed implementation point and test or acceptance checkbox from `[ ]` to `[x]`. A required item that remains incomplete means the task is not ready to commit.
- Add or update an exact `## Implementation Verification` section. Record the implemented behavior and principal files or symbols, the focused validation commands and their results, and any accepted limitations or follow-up owned by later tasks. Include only evidence produced during the implementation.

Next, update the master index (the `README.md` file or index document that points to the task) by changing the task's **Implemented** cell from `[ ]` to `[x]`.

Stage all changes together: the implementation code, the updated task document, and the updated index. When the task document and implementation live in different repositories, make the corresponding task commit in each affected repository containing the relevant updates for that repository, and record both commit IDs.

As soon as a task succeeds, its integration owner creates the single commit with this exact first line, substituting the task number and specification basename:

```text
Implement Task {task number} of {spec_file_name}
```

Include a detailed body describing the implemented behavior, significant changes, and validation performed. Keep one task's implementation distinct from other tasks; do not squash a parallel batch into a single task commit. Stage only that task's changes.

Integrate the task into the designated destination and run the checks needed to verify the integrated result. Preserve the task commit when merging. Delegate code changes needed for conflicts or failing integration checks. In a parallel batch, serialize Git integration even while other workers continue implementing.

When the outer orchestrator integrates a batch, verify that the single task commits (including their index updates) reached the original target. A prerequisite becomes available to later dispatches only at this point.

Remove temporary worktrees and branches created by this run only after verifying that their changes are integrated and they contain no uncommitted work. Preserve failed or unmerged work for recovery.

Completion criterion: the implementation is committed and integrated, required checks pass, the task document records implemented status and verification evidence, and the master index reflects the completion in exactly one task commit. Only then advance to dependent work.

## 5. Finish or report a blocker

Continue until every selected task meets the completion criterion. If a failure leaves tasks blocked, preserve their pending status and report the exact dependency or failed check. Ready, independent tasks within the original selection may still proceed.

Report completed task numbers, commit IDs, validation results. If any selected tasks are still blocked, report them. On resumption, re-read the index and Git history so an interruption between implementation commit and checkbox update does not cause duplicate implementation.

Notify either still blocked tasks or the completion of the implementation to the user using `ask_telegram` tool if it is available in your environment. If `ask_telegram` is not available, try the `rpiv-ask-user-question` tool, and if not available, fall back to the standard `ask_user_question` tool or terminal prompts. On your notifications of blocked tasks, write it like you are talking to a human, not a technical person (don't use code language). Use business domain terms, plain language, clear and concise, and avoid unnecessary verbosity.
