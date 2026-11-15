---
name: orchestrator-handoff
description: >-
  Hand an orchestrated run from a worn session to a fresh one: stop at the first clean point, write the run's handover, clean up, and give the next session its prompt. Use when the orchestrator reaches a handoff point, or when the user asks to hand off, switch to a new session or start fresh during an orchestrated run.
---

# Orchestrator handoff

A conductor session loses detail at every compaction. A fresh session reading the run's files loses none. So the conductor hands over at a **clean point**: no worker running, no correction pending.

This runs inside the [orchestrator](../orchestrator/SKILL.md) skill; that skill covers the run files, dispatch, checks, integration and Codex cleanup (cited below as orchestrator §n). Load it first if you are not already conducting.

You cannot close the session. You stop dispatching, prepare everything, tell the user, and wait.

## 1. Recognize the moment

Hand off at the first clean point after any one of:

- every task of a plan or spec is integrated, or merged to the main branch, or a run closes;
- about four hours since the session started;
- the session's second compaction;
- the user asks.

The ledger's `session started` line dates the four hours and its `context compacted` lines count the compactions (orchestrator, "Run files"). Claude and DeepSeek workers end with the session; a Codex job can outlive it, so its result is collected here.

Done when: one trigger holds. Step 2 reaches the clean point.

## 2. Drain

Dispatch nothing new. Let running workers finish, then check and integrate their results as orchestrator §6 says. A task their integration unblocks stays planned in the ledger, for the next session.

Done when: no worker is running, every result is checked, and the accepted work is integrated.

## 3. Write the handover

Write `runs/<run>/handover.md` with only what the ledger and the repos do not already hold, pointing to them for the rest:

- the state in a few lines: what is integrated and where, what is held and why;
- the exact next step;
- the branches and worktrees in use;
- the counters the run keeps: next decision number, next question number, last message id;
- notes later tasks need that the ledger lacks;
- anything owed to the user.

A fresh conductor reads this before anything else, so keep it short.

Done when: a conductor holding this file and the files it names can take the next step without asking.

## 4. Clean up

Release each Codex runtime with the cleanup helper (orchestrator §6, "Release finished Codex runtimes"). Remove the worktrees of integrated tasks. Leave the run open when work remains.

Done when: the ledger records a runtime result for every Codex checkout, and no integrated task's worktree remains.

## 5. Write the next session's prompt

Write `.scratch/orchestrator/next-session-prompt.md`:

- the start command, when the standing instructions name one;
- a short prompt: act as conductor with the orchestrator skill, read `standing-instructions.md`, `workers.md` and the run's `handover.md`, then that run's `ledger.md` and `rules.md`, and continue.

It points to the standing instructions; their file keeps the only copy.

Done when: the prompt names every file the next session reads, in reading order, and a fresh session started with it reaches the next step.

## 6. Tell the user

Say, through the channels the standing instructions name, the terminal included:

- that now is a good moment to switch, and which trigger fired;
- what was finished;
- the prompt's path and the start command.

Then end the turn and wait. If the user says to continue instead, carry on and check again at the next integration.

Done when: the message is sent on every named channel and your turn has ended.
