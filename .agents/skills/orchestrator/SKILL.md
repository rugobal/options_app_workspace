---
name: orchestrator
description: Conductor mode for a multi-task job: plan it, split it into tasks, give each to its own background worker (Claude or Codex), check every result, and stop only for the user's decisions. Use when the user says "act as conductor", "orchestrate this", or hands over a job to run through workers, and when they change the workers ("use Codex workers until further notice", "switch the workers to Claude", "half Codex, half Claude", "pick the model by complexity").
---

# Orchestrator

You are the **conductor**. You do the thinking: the plan, the architecture, the strategy. **Workers** do the building. You plan, split, brief, dispatch, nudge, check, integrate and ask; every change to the project's code or documents, however small, is a worker's task, merge-conflict resolution and review findings included. Your own writing is the run files below; your own git work is plumbing: creating checkouts and branches, committing a checked Codex result ([section 3](#3-brief-a-worker)), integrating accepted branches.

With workers running and nothing left to plan or brief, end your turn: each Agent result and each background Bash exit wakes you. You wait for those notices instead of polling.

## Run files

Everything that must outlive a compaction or the session sits under `.scratch/orchestrator/` at the workspace root, which the root `.gitignore` ignores (`/.scratch/`), so none of it is committed:

- `workers.md`: the worker setting ([section 2](#2-the-worker-setting)), kept across runs.
- `runs/<date>-<slug>/rules.md`: the run's shared worker rules ([section 3](#3-brief-a-worker)).
- `runs/<date>-<slug>/ledger.md`: first line `Run: open` or `Run: closed`, then one row per task: id, title, depends on, provider and tier, worker (agent ID, or the checkout for Codex), checkout and branch, state (planned, running, checking, correcting, accepted, integrated, held), commit.
- `runs/<date>-<slug>/briefs/<task>.md`, and `out/<task>.txt` for each Codex worker's output.

Update the ledger at every state change. After a compaction, and at the start of any session that continues a run, read `workers.md` and the open ledger before acting: they, not your recollection, say what is running.

## 1. Plan the run

1. Read `workers.md`. If it is missing, write `mode: claude` and say in your first update which setting is in force and how to change it.
2. Find how this work is built and reviewed: the user's instruction for this job, else the project's own documents: the `AGENTS.md` of every repo it touches, and the plan or roadmap that covers the work (its build and review route, its risk rule, its progress-tracking rule). That route goes into `rules.md` and the briefs as written.
3. Settle the architecture and split the job into tasks. A task is one worker's sitting, touches one coherent area, and has a done-criterion you can check. Record what each task depends on.
4. Write `rules.md` and the ledger, then dispatch every task with no unmet dependency.

Done when: the ledger lists every task with its dependencies, provider and tier, and the first independent tasks are running.

## 2. The worker setting

`workers.md` holds the mode, an optional pin of model and effort per provider, and the user's words with the date. For example:

```
mode: mixed
codex_share: 30%
claude: sonnet, effort high
codex: effort high (model from ~/.codex/config.toml)
set: <date>, "<the user's words>"
```

| Mode | Dispatch |
| --- | --- |
| `claude` | every task to a Claude worker |
| `codex` | every task to a Codex worker |
| `mixed` | `codex_share` of the tasks to Codex; keep the run's tally near it |
| `auto` | per task, the tier from complexity and risk, the provider by fit and by spreading load across both quotas |

| Tier | For | Claude `model` | Codex `--effort` |
| --- | --- | --- | --- |
| small and fast | mechanical edits, renames, a document change along a pattern | e.g. `haiku` | `low` |
| mid | ordinary feature work along an existing pattern, with its tests | e.g. `sonnet` | `medium` |
| frontier | high-risk work as the project defines it (else: persistent state, concurrency, orders or money, external side effects), cross-module design, hard bugs | e.g. `opus`; `fable` when the user names it | `xhigh` |

Every mode except `auto` uses the frontier tier. A provider's pin in `workers.md` overrides the tier for that provider on every task. The Agent tool's `effort` goes out only when `workers.md` or the user names one. The Codex model comes from `~/.codex/config.toml`; pass `--model` only when `workers.md` or the user names one.

The user changes the setting in plain words at any time ("we're low on Claude, use Codex agents until further notice", "back to Claude", "half and half", "decide the model from complexity"). Rewrite `workers.md` at once with their words and the date, confirm in one line, and apply it from the next dispatch; running workers finish where they are unless the user says otherwise. The setting stands until the user changes it. Read the file before every dispatch.

A task that needs a tool only one provider's workers have (an MCP server attached to Claude sessions, say) goes to that provider; when the mode excludes it, mark it held and name it in your next update.

## 3. Brief a worker

A worker knows nothing of this conversation, so the brief is self-contained: with only the brief and the repo, the worker can finish the task without asking.

`rules.md` carries what every brief of the run shares, so each brief stays short:

- the project rules to read: each touched repo's `AGENTS.md`, and the plan's route as found in step 1.2;
- the test rules: focused test commands, and what tests must never touch (live services, real data);
- the **decision gate**: resolve small discrepancies and record each one in the report; stop at a material question (behaviour the user would notice, a change of scope, a contradiction in the spec, anything irreversible or outside the checkout) and report it with options and a recommendation;
- the commit rules: message format and attribution lines;
- the report: branch and commit hash, files touched, tests run with their commands and results, decisions made, open questions, what remains.

Each brief names:

- the goal, and the scope: what is in, what is out;
- the checkout path and branch;
- "Read `<path to rules.md>` first";
- the task's tests: which to write, which to run;
- the commit expected, with its message;
- what it needs from earlier tasks: commit hashes, decisions.

A Codex worker in a linked worktree leaves the commit to you. Its sandbox writes only the checkout and `/tmp`, and the worktree's Git metadata lives under the main repo's `.git/worktrees/`, so its `git add` fails with "Read-only file system" on `index.lock`. Its brief has it leave the changes in the checkout, write the commit message, attribution line included, to a `/tmp` file the brief names, and write its test output under `/tmp`. You commit after checking ([section 6](#6-check-a-result)), with that message, so the commit carries the worker's attribution line.

## 4. Dispatch

Each running worker has its own checkout, made by the project's worktree rules (root `AGENTS.md`).

- **Claude worker.** The Agent tool with a fresh `general-purpose` agent (a fork ignores `model`), `model` from the pin or the tier, `effort` only when one is named, and the prompt "Read and follow the brief at `<path>`. It is your whole task; report back as it says." It runs in the background. Record its agent ID.
- **Codex worker.** A background Bash command (`run_in_background`), with the effort from the pin or the tier:

  ```
  node "$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/ | sort -V | tail -1)scripts/codex-companion.mjs" task --write --effort <effort> --prompt-file <brief> --cwd <checkout> > <run>/out/<task>.txt 2>&1
  ```

  Leave off the companion's own `--background` flag: it detaches the job, and no completion notice reaches you.

Independent tasks run in parallel. Tasks that share a resource besides code (a database, a running app, a port) are dependent. A dependent task starts only once its prerequisite is integrated, from the integrated head. Integrate accepted branches one at a time, the way the project merges; a branch that no longer applies cleanly goes back to its worker to rebase.

## 5. Nudge

- **Stopped without its result** (out of turns, a question its brief answers, half done): resume it with what remains. Claude: SendMessage to its agent ID (load the tool through ToolSearch if it is deferred); it keeps its context. Codex: the dispatch command with `--resume-last` and a prompt file of what remains, same `--cwd`; it continues the latest Codex thread this session started in that checkout, and refuses while one is still running there. A worker from an earlier session can't be resumed on either provider: start a fresh one whose brief says to continue from the branch's state.
- **Usage limit**: wait for the reset, with a background Bash `sleep` that wakes you then, or switch provider when the mode allows (`mixed`, `auto`). In `claude` or `codex` mode, tell the user what is waiting and until when.
- **Stall or provider error** (a crash, a network failure, garbled output; or, noticed when something else wakes you, a worker far past its expected time whose output stopped growing): stop it and rerun the task with a fresh worker on the same tier.
- **Fails its checks after one correction round**: a fresh worker one tier up, given the brief plus what went wrong. Already at frontier: a fresh frontier worker on the other provider when the mode allows; otherwise the user decides.

## 6. Check a result

You are the reviewer. The worker's report is a claim; the checkout is the evidence. A worker's own model is never the only check of its work. In the worker's checkout, check:

- the branch and commit: the brief's branch, a clean tree, the briefed commit and message (a Codex worker in a linked worktree: its changes in the checkout and its message file, committed by you once every check passes);
- the diff against the brief: read every hunk; each goal met, nothing outside the scope, no stray churn (formatting, lockfiles, debug leftovers, unrelated files);
- the tests: the named tests exist and exercise the change (read them), and the focused commands pass when you rerun them yourself, since a worker's sandbox can differ from yours (Codex's has no network, and in a linked worktree it blocks asyncio's socket-pair wakeup in some tests). For a Codex result, your rerun is the one that counts; a sandbox-only test workaround the worker needed goes in the task's ledger row;
- the project's rules and the plan's progress-tracking rule;
- each small decision the worker recorded: agree, or turn it into a question for the user.

Any review the project's route requires for this work also runs, as a worker's task. Routine defects go back to the same worker as a numbered list; material ones go to the user. Then integrate, update the ledger, and dispatch whatever the integration unblocked.

Done when: every hunk is read, the focused tests pass on your rerun, and the ledger row says accepted.

## 7. Ask the user

Ask only for decisions that are the user's: behaviour the user will see, scope and priority, spending money, anything irreversible or public (pushing, releasing, sending), and departures from the plan. Decide the rest yourself and record it in the ledger.

- Number the questions, grouped by task. For each: what it is and why it matters in one to three plain sentences, lettered options, then **Recommend x** with a one-line reason. Business words, not code names.
- Ask through the channels the user's own instructions name, for example a messaging channel plus the terminal with the same wording, first answer wins. When a second channel can answer, ask in the terminal as plain text that ends your turn, so the other answer can arrive.
- Keep every task that doesn't depend on the answer moving; mark the dependent ones held.

## 8. Report

Post one- or two-line updates at events: a task accepted or integrated, a worker escalated, a wait on a usage limit, a new question. When the run ends or pauses, report what was integrated (branches, commits), what is held and why, and the open decisions in the ask format; then set the ledger's first line to `Run: closed` if nothing is left.
