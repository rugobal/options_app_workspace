---
name: dual-design
description: >-
  Dual design: settle a design (a refactor group, an architecture choice, a module's shape) through two blind proposals, one from a Claude worker and one from a Codex worker, reconciled with evidence by a neutral conductor. Use when the user asks for a dual design or two independent Claude and Codex proposals, or when a conductor must settle a refactor group's design before any code is written.
---

# Dual design

Two proposers design the same thing **blind**, from one brief. A **neutral** conductor compares the proposals, runs rounds on what differs, and records every decision with its evidence. This is the owner's process (2026-11-13, amended in 486a).

It runs inside the [orchestrator](../orchestrator/SKILL.md) skill; load that first if you are not already conducting. The run files, the worker setting, dispatch, nudging, result checks, Codex cleanup and the ask format work as written there, cited below as orchestrator §n. Both providers belong to this process whatever the worker setting's mode; its pins of model and effort still apply. When the user has excluded a provider, hold the group and ask.

Steps 1 to 7 write run files and, in step 7, the design documents. Code comes after step 8.

## Roles

- **Conductor**: you, the orchestrator session, **neutral** throughout: here the design is the proposers' work, and you judge it. You write the brief, compare, run the rounds, decide what your delegation allows, and keep the [decision log](#the-decision-log).
- **Proposers**: one fresh Claude worker and one Codex worker. Each writes its own proposal and later argues its own side.
- **Owner**: decides what remains open.

## 1. Choose the process tier

- **Full** for high-risk designs (the project's risk rule; without one: persistent state, broker orders or events, state shared across threads, money and price maths), cross-module seams and data-model changes.
- **Light** for designs that mostly move code. Steps 2 and 3 run with one proposer, from the provider the worker setting picks. A worker of the other provider then critiques that proposal once, read-only on the same commit, given the brief and the proposal: every point it would change, with evidence. Save the critique as `critique.md` beside the proposal. In place of steps 4 and 5, log every section of the proposal: what the critique leaves standing as `agreed`, each critique point as open. Steps 6 and 7 follow as written.

Done when the ledger records the tier of every group in the run.

## 2. Write the blind brief

One brief, identical for both proposers, at `briefs/<group>-design.md`. It gives the **what** and leaves the **how** to the proposers. It carries:

- the goal;
- per item: the problem, its files, and the direction the owner already chose; any solution or diagram from an earlier review stays out;
- what to read: the plan sections, the glossary, the style rules, each touched repo's `AGENTS.md`;
- the fixed constraints: the decisions already made, listed so nobody re-litigates them;
- the plan's known stale facts, as evidence to verify;
- the simplicity rule and the evidence rule, verbatim, and the proposal template, all from [Brief text](#brief-text);
- the checkout and its commit, and that the task is read-only: the proposal is the worker's final answer.

Done when a proposer holding only the brief and the repo can write the proposal.

## 3. Dispatch both proposers

Dispatch both at once, read-only, on one detached worktree at the brief's commit, as orchestrator §4 does, with Codex's `task --fresh` run without `--write`: the companion then runs it read-only. Until step 5, each proposer sees only the brief and the repo.

A group's Codex proposer needs a checkout no other Codex task uses until the group leaves step 5: `--resume-last` continues this session's newest Codex task in that checkout, and refuses while another one runs there.

Save each proposal as it arrives, as `claude.md` and `codex.md` in the group's [design folder](#the-decision-log).

Done when both proposals are saved and each has every template section; a proposal missing one goes back to its own proposer (orchestrator §5) before step 4.

## 4. Compare

List every difference between the proposals, a point one makes and the other leaves out included, and classify it:

- **material**: it changes an interface, the data model, behaviour, what the tests cover, or the build order;
- **cosmetic**: names, file placement, local style. Decide it by the simplicity rule and log the reason.

Points both proposals share go in the log as `agreed`, with their reason. You may hand the mechanical difference list to a fresh neutral worker given both proposals; check its list against both proposals before using it.

Done when every section of both proposals is accounted for in the decision log: agreed, decided as cosmetic, or an open material point.

## 5. Run the rounds

Per round, each proposer gets one message holding every open material point: the other side's position and evidence, quoted from its proposal or last answer. It answers accept, reject or counter per point, with evidence (paths, call sites, test names); an accept names the evidence that changed its mind. A point is `agreed in round n` once both sides hold the same position. At most three rounds per group.

Each proposer answers in its own context (orchestrator §5): Claude through SendMessage; Codex through `task --resume-last`, without `--write`, in the same checkout, with the round message as the prompt file, each round the next attempt on its ledger row. A proposer from an earlier session is out of reach of both: a fresh worker of the same provider takes its side, given the brief, that side's saved proposal and answers, and the round message.

Save each answer as `round<n>-claude.md` and `round<n>-codex.md` in the design folder, then update the log. Once the group leaves this step, release the Codex proposer's runtime (orchestrator §6, "Release finished Codex runtimes").

Done when every material point is agreed or the third round is answered.

## 6. Close the open points

For each point still open:

- **Within your delegation** (the kinds of decision the user delegated, for example the order of work or purely technical choices): decide it, log it as `conductor decided`, and list it in your next report for the owner to overturn.
- **Otherwise**: ask the owner, marked "needs human decision", in the ask format (orchestrator §7), one option per side with its argument and evidence. Log the answer as `owner`.

Done when no point in the log is open.

## 7. Write the design

A worker writes the final design into the documents the project names (for Epic 7: the plan's Review decisions entries, its design sections and requirements, and new terms in the glossary), from the decision log alone. A worker of the provider that did not write it checks the written design once against the log, read-only: every decision present, nothing added. Its findings go back to the writer. Then you read the diff (orchestrator §6).

Done when the documents carry every logged decision and nothing else, and you have read every hunk.

## 8. Plan the build, later

Just before a group is built, the project's planning skill (`/tasks` here) writes the implementation plan from the written design; a worker of the other provider critiques it once; you settle each critique point. The two-proposal debate settles designs; a task plan takes one writer and one critique.

Done when every critique point is applied to the plan or rejected with its reason in the ledger.

## The decision log

`runs/<run>/design/<group>/decisions.md`, in the group's design folder beside the saved proposals and answers. It opens with the group, its tier, the commit and the brief's path, then one row per point:

| id | point | kind | decision | reason | evidence |
| --- | --- | --- | --- | --- | --- |

Kinds: `agreed`, `cosmetic`, `agreed in round n`, `conductor decided`, `owner` (with the question number), and, until a point closes, `open after round n` (0 before the first round). Evidence is the `path:line`, call site, test or plan section the decision rests on.

The log is the design's single source: step 7 writes from it, and after a compaction or a restart it says, with the ledger, where each group stands.

## Deviations

A one-off deviation from this process goes in the run's ledger with its reason, and the user's words when they asked for it. A lasting change is an edit to this skill, made by a worker with the owner's agreement.

## Brief text

### The simplicity rule

> The code must be clear for a human to understand and as concise as possible, provided it does its job. For every module ask: can this be simpler? When in doubt, the simplest design that does the job wins.
> - The job is today's behaviour, as the behaviour tests lock it in, plus what the named next consumers need from this code. Nothing else.
> - Simpler means, in this order: fewer concepts a reader must hold to make one change; one place to change per behaviour; smaller interfaces; then fewer lines.
> - A seam needs two real adapters (a test fake counts only when tests use it at that seam). No option or setting nobody asked for. The old path is deleted in the same change.

### The evidence rule

> Every claim about the code cites `path:line` at the brief's commit. Mark anything you could not verify **unverified**.

### The proposal template

1. **Summary.**
2. **Modules**: one section per module, named in the glossary's terms, new terms marked. Each covers:
   - its interface: operations, invariants, ordering, error modes, and thread or transaction rules;
   - what sits behind it;
   - its seam and adapters;
   - callers moved and code deleted, by `path:line`.
3. **Data model and migrations.**
4. **Behaviour changes**, each with what a user would notice.
5. **Tests**: kept, rewritten, deleted, new; which behaviour tests must exist first.
6. **Build order**, each step leaving the suite green.
7. **Amendments to the plan**, with evidence.
8. **Open questions**, each marked **owner** or **technical**, with a recommendation.
9. **Simplicity check**, per module: the simpler alternative considered, and why it was taken or rejected.

Aim for under 600 lines; cite code, don't paste it.
