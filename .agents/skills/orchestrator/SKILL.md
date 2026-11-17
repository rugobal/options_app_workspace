---
name: orchestrator
description: >-
  Conductor mode for a multi-task job: plan it, split it into tasks, give each to its own background worker (Claude, Codex, DeepSeek or Gemini through Antigravity), check every result, and stop only for the user's decisions. Use when the user says "act as conductor", "orchestrate this", or hands over a job to run through workers, and when they change the workers ("use Codex workers until further notice", "switch the workers to Claude", "half Codex, half Claude", "give DeepSeek a third", "add Gemini through Antigravity", "pick the model by complexity").
---

# Orchestrator

You are the **conductor**. You do the thinking: the plan, the architecture, the strategy. **Workers** do the building. You plan, split, brief, dispatch, nudge, check, integrate and ask; every change to the project's code or documents, however small, is a worker's task, merge-conflict resolution and review findings included. Your own writing is the run files below; your own git work is plumbing: creating checkouts and branches, committing a checked Codex result ([section 3](#3-brief-a-worker)), integrating accepted branches.

With workers running and nothing left to plan or brief, end your turn: each Agent result and each background Bash exit wakes you. You wait for those notices instead of polling.

## Run files

Everything that must outlive a compaction or the session sits under `.scratch/orchestrator/` at the workspace root, which the root `.gitignore` ignores (`/.scratch/`), so none of it is committed:

- `standing-instructions.md`: the user's lasting instructions on how you work, kept across runs. Worker choices live in `workers.md`, never here. When the user gives a new lasting instruction, rewrite the matching item with their words and the date, as for `workers.md`.
- `workers.md`: the worker setting ([section 2](#2-the-worker-setting)), kept across runs.
- `runs/<date>-<slug>/rules.md`: the run's shared worker rules ([section 3](#3-brief-a-worker)).
- `runs/<date>-<slug>/ledger.md`: first line `Run: open` or `Run: closed`, then a `session started <time>` line per session continuing the run and a `context compacted` line after each compaction, then one row per task: id, title, depends on, provider and tier, worker (Claude agent ID; background Bash task ID plus Codex job ID, DeepSeek session ID or Antigravity conversation ID and scope per attempt), checkout and branch, state (planned, running, checking, correcting, accepted, integrated, held), commit, Codex runtime cleanup (pending, stopped, or skipped with reason).
- `runs/<date>-<slug>/briefs/<task>.md`, and `out/<task>-<attempt>.txt` for each Codex attempt's output (`.json` for DeepSeek and Antigravity).

Update the ledger at every state change. After a compaction, and at the start of any session that continues a run, record `context compacted` or `session started <time>`, then read `standing-instructions.md`, `workers.md` and the open ledger before acting: they, not your recollection, say how to work and what is running.

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
deepseek_share: 20%
deepseek: compact window 300000
antigravity_share: 10%
antigravity: model gemini-4-argon, effort high
set: <date>, "<the user's words>"
```

| Mode | Dispatch |
| --- | --- |
| `claude` | every task to a Claude worker |
| `codex` | every task to a Codex worker |
| `deepseek` | every task to a DeepSeek worker |
| `antigravity` | every task to an Antigravity worker |
| `mixed` | `codex_share`, `deepseek_share` and `antigravity_share` of the tasks to those providers, the rest to Claude; keep the run's tally near them |
| `auto` | per task, the tier from complexity and risk, the provider by fit and by spreading load across the quotas |

| Tier | For | Claude `model` | Codex `--effort` | DeepSeek `--effort` | Antigravity `--model`, `--effort` |
| --- | --- | --- | --- | --- | --- |
| small and fast | mechanical edits, renames, a document change along a pattern | e.g. `haiku` | `low` | `low` | `gemini-3.8-flash`, `low` |
| mid | ordinary feature work along an existing pattern, with its tests | e.g. `sonnet` | `medium` | `medium` | `gemini-3.8-flash`, `medium` |
| frontier | high-risk work as the project defines it (else: persistent state, concurrency, orders or money, external side effects), cross-module design, hard bugs | e.g. `opus`; `fable` when the user names it | `xhigh` | `high` | `gemini-4-argon`, `high` |

DeepSeek is the budget provider: in `mixed` and `auto`, give it the small and mid tasks first, and frontier tasks only when `workers.md` or the user says so. Every mode except `auto` uses the frontier tier. A provider's pin in `workers.md` overrides the tier for that provider on every task. The Agent tool's `effort` goes out only when `workers.md` or the user names one. The Codex model comes from `~/.codex/config.toml`; pass `--model` only when `workers.md` or the user names one.

The user changes the setting in plain words at any time ("we're low on Claude, use Codex agents until further notice", "back to Claude", "half and half", "decide the model from complexity"). Rewrite `workers.md` at once with their words and the date, confirm in one line, and apply it from the next dispatch; running workers finish where they are unless the user says otherwise. The setting stands until the user changes it. Read the file before every dispatch.

A task that needs a tool only one provider's workers have (an MCP server attached to Claude sessions, say) goes to that provider; when the mode excludes it, mark it held and name it in your next update.

## 3. Brief a worker

A worker knows nothing of this conversation, so the brief is self-contained: with only the brief and the repo, the worker can finish the task without asking.

`rules.md` carries what every brief of the run shares, so each brief stays short:

- the project rules to read: each touched repo's `AGENTS.md`, and the plan's route as found in step 1.2;
- the test rules: each task runs only its focused tests, the files holding its changed or new tests plus one or two files that test the changed functions directly (typically 2-6 files), each run once; the whole suite runs once, after every implementation task of the spec is done; and what tests must never touch (live services, real data);
- the **decision gate**: resolve small discrepancies and record each one in the report; stop at a material question (behaviour the user would notice, a change of scope, a contradiction in the spec, anything irreversible or outside the checkout) and report it with options and a recommendation;
- the commit rules: message format and attribution lines;
- the report: branch and commit hash, files touched, tests run with their commands and results, decisions made, open questions, what remains.

Each brief names:

- the goal, and the scope: what is in, what is out;
- the checkout path and branch;
- "Read `<path to rules.md>` first";
- the task's tests: which to write, and its focused file list to run, each file named;
- the commit expected, with its message;
- what it needs from earlier tasks: commit hashes, decisions.

A Codex worker in a linked worktree leaves the commit to you. Its sandbox writes only the checkout and `/tmp`, and the worktree's Git metadata lives under the main repo's `.git/worktrees/`, so its `git add` fails with "Read-only file system" on `index.lock`. Its brief has it leave the changes in the checkout, write the commit message, attribution line included, to a `/tmp` file the brief names, and write its test output under `/tmp`. You commit after checking ([section 6](#6-check-a-result)), with that message, so the commit carries the worker's attribution line.

## 4. Dispatch

Each running worker has its own checkout, made by the project's worktree rules (root `AGENTS.md`).

- **Claude worker.** The Agent tool with a fresh `general-purpose` agent (a fork ignores `model`), `model` from the pin or the tier, `effort` only when one is named, and the prompt "Read and follow the brief at `<path>`. It is your whole task; report back as it says." It runs in the background. Record its agent ID.
- **Codex worker.** Find the `codex@openai-codex` entry in `~/.claude/plugins/installed_plugins.json` that matches this session's scope and project. Append `scripts/codex-companion.mjs` to its `installPath`. Check that the file exists and record its absolute path as `<companion>` in `rules.md`. If it cannot be found, hold Codex tasks and say why. Resolve [scripts/cleanup-codex-companion.py](scripts/cleanup-codex-companion.py) relative to this skill's directory and record its absolute path as `<cleanup>` there too.

  Run it in background Bash (`run_in_background`), with absolute paths and the effort from the pin or tier:

  ```
  node "<companion>" task --fresh --write --effort <effort> --prompt-file "<brief>" --cwd "<checkout>" > "<run>/out/<task>-<attempt>.txt" 2>&1
  ```

  Record Bash's background task ID immediately. Run `node "<companion>" status --cwd "<checkout>" --json` after launch. The checkout has at most one running `kind: task` job; record its `id` (`task-…`) for this attempt. If it is not listed yet, record it at the next wake-up. Each correction or retry takes the next attempt number and keeps earlier attempts' files and IDs.

  Leave off the companion's own `--background` flag so Bash's notice marks completion.
- **DeepSeek worker.** Headless Claude Code on DeepSeek through OpenRouter, via [scripts/deepseek-worker.sh](scripts/deepseek-worker.sh); record its absolute path as `<deepseek>` in `rules.md`. It reads the OpenRouter key from `OPENROUTER_API_KEY` or `~/.config/openrouter/api_key`; with neither, hold DeepSeek tasks and say why. Run it in background Bash, with the effort from the pin or tier and the compact window from `workers.md` (default 300000 tokens):

  ```
  "<deepseek>" --brief "<brief>" --cwd "<checkout>" --effort <effort> --compact-window <tokens> > "<run>/out/<task>-<attempt>.json" 2> "<run>/out/<task>-<attempt>.err"
  ```

  Record Bash's background task ID. The worker has the full Claude Code toolset and commits itself, like a Claude worker. Its `.json` file is one object; record its `session_id` in the ledger row. Its `total_cost_usd` is Claude Code's guess at Claude prices for an unknown model, about six times the real figure; the real spend is the change in `usage` from `GET https://openrouter.ai/api/v1/key` with the key as Bearer token.
- **Antigravity worker.** Google's Gemini through the Antigravity CLI (`agy`) in print mode, via [scripts/antigravity-worker.sh](scripts/antigravity-worker.sh); record its absolute path as `<antigravity>` in `rules.md`. It needs `agy` signed in (`agy models` lists the model ids). The checkout must sit inside agy's trusted workspaces (`~/.gemini/antigravity-cli/settings.json`): outside them agy quietly works in its own scratch folder, so the wrapper refuses. When either is missing, hold Antigravity tasks and say why. Run it in background Bash, with the model and effort from the pin or tier. The wrapper's defaults are the frontier pair, `gemini-4-argon` at `high`. Each model offers only some efforts; `agy models` lists the pairs.

  ```
  "<antigravity>" --brief "<brief>" --cwd "<checkout>" --model <model> --effort <effort> > "<run>/out/<task>-<attempt>.json" 2> "<run>/out/<task>-<attempt>.err"
  ```

  Record Bash's background task ID, and the systemd scope named on the `.err` file's first line. The brief goes in as the prompt itself, so keep it under 120000 characters. The worker runs with every tool approved and commits itself, like a DeepSeek worker. On Argon it takes the same frontier work as Claude and Codex workers. Its `.json` file is one object; record its `conversation_id`. The wrapper's `--timeout` (default `3h`) is agy's own print-mode limit. agy and every process the worker starts run in that scope, and the wrapper stops the scope when agy exits or the wrapper is stopped, so nothing the worker started outlives it and its memory is released. Docker containers belong to dockerd, outside the scope: tests remove their own.

Independent tasks run in parallel. Tasks that share a resource besides code (a database, a running app, a port) are dependent. A dependent task starts only once its prerequisite is integrated, from the integrated head. Integrate accepted branches one at a time, the way the project merges; a branch that no longer applies cleanly goes back to its worker to rebase.

## 5. Nudge

- **Inspect a Codex worker** for a suspected stall: `node "<companion>" status "<job-id>" --cwd "<checkout>" --json`. When a Claude session ends normally, the plugin stops only the Codex jobs in the session's own working directory. A worker in another checkout (every worktree worker), or any worker after a crash, can still be running. Look it up by its recorded ID, which also finds earlier sessions' jobs, then cancel it or let it finish.
- **Stopped without its result** (out of turns, a question its brief answers, half done): resume it with what remains. Claude: SendMessage to its agent ID (load the tool through ToolSearch if it is deferred); it keeps its context. Codex: replace `--fresh` with `--resume-last` in the dispatch command and use a brief of what remains, with the same `--cwd`. It resumes this session's latest task thread there and refuses while one is running. DeepSeek: rerun the dispatch command with `--resume <session_id>`, a brief of what remains, and the same `--cwd`. Antigravity: the same, with `--resume <conversation_id>`. For a worker from an earlier session, start fresh with a brief that continues from the branch's state.
- **Usage limit**: wait for the reset, with a background Bash `sleep` that wakes you then, or switch provider when the mode allows (`mixed`, `auto`). In `claude` or `codex` mode, tell the user what is waiting and until when.
- **Stall or provider error** (a crash, network failure, garbled output, or a worker far past its expected time with no new output): stop it and rerun with a fresh worker on the same tier. For Codex, cancel with `node "<companion>" cancel "<job-id>" --cwd "<checkout>" --json`: stopping Bash alone can leave the shared Codex background process working in the checkout. Confirm with `status` before replacing it. For DeepSeek, stopping the background Bash task stops the worker. For Antigravity, stopping it makes the wrapper stop its scope; when the wrapper was killed outright, stop the scope by its recorded name: `systemctl --user stop <scope>`.
- **Fails its checks after one correction round**: a fresh worker one tier up, given the brief plus what went wrong. Already at frontier: a fresh frontier worker on the other provider when the mode allows; otherwise the user decides.

## 6. Check a result

Read DeepSeek's output JSON first: `is_error` and `result`. Read Antigravity's first: `status` (`SUCCESS` or `ERROR`), `error` and `response`. Read Codex's launch output first. If its report is missing, retrieve the stored report or failure with `node "<companion>" result "<job-id>" --cwd "<checkout>" --json`.

You are the reviewer. The worker's report is a claim; the checkout is the evidence. A worker's own model is never the only check of its work. In the worker's checkout, check:

- the branch and commit: the brief's branch, a clean tree, the briefed commit and message (a Codex worker in a linked worktree: its changes in the checkout and its message file, committed by you once every check passes);
- the diff against the brief: read every hunk; each goal met, nothing outside the scope, no stray churn (formatting, lockfiles, debug leftovers, unrelated files);
- the tests: the named tests exist and exercise the change (read them), and the focused commands pass when you rerun them yourself on the brief's same file list, since a worker's sandbox can differ from yours (Codex's has no network, and in a linked worktree it blocks asyncio's socket-pair wakeup in some tests). For a Codex result, your rerun is the one that counts; a sandbox-only test workaround the worker needed goes in the task's ledger row. The whole suite runs once, when every task of the spec is done;
- the project's rules and the plan's progress-tracking rule;
- each small decision the worker recorded: agree, or turn it into a question for the user.

Any review the project's route requires for this work also runs, as a worker's task. Routine defects go back to the same worker as a numbered list; material ones go to the user. Then integrate and update the ledger. After each integration, and after each compaction, check the handoff triggers: when one holds, follow the [orchestrator-handoff](../orchestrator-handoff/SKILL.md) skill instead of dispatching again. Otherwise dispatch whatever the integration unblocked.

Done when: every hunk is read, the focused tests pass on your rerun, and the ledger row says accepted.

### Release finished Codex runtimes

The parent conductor owns this cleanup. Companion 1.0.6 can keep completed threads and their MCP/REPL helpers loaded after the worker exits. A worker's final answer, a Bash exit, or `cancel` alone does not release the shared broker.

After collecting the result and accepting a Codex task, clean its checkout before dispatching more work and before removing its worktree; a worktree already removed is cleaned by its old path. Also clean a cancelled or failed attempt once its failure is recorded and you have decided to replace it with a fresh worker. Keep the runtime while planning to use `--resume-last`, while a correction or approval is pending, or when the user wants a background service to keep running.

Run from the parent on the host, using this skill's helper:

```
python3 "<cleanup>" --workspace "<checkout>" --execute
```

This inspects only that checkout. It checks the broker's process identity, saved terminal job results, idle/error thread status, connected clients, and descendant helpers before sending `broker/shutdown`. It leaves saved results and conversation files in place and checks that the original process tree exited. The plugin starts a new broker on the next task. Omitting `--execute` performs a dry-run. The helper is Linux-only (it reads `/proc` and `ss`); on another OS it reports `skipped`, and the runtime lasts until the session ends.

Record `stopped` or `not-running` in the ledger. On `skipped` or `incomplete` (exit 2), record the reason; do not replace this with `pkill`, a global process kill, or repeated polling. Revisit it once at a later natural wake-up if the reason has cleared. Do not start another task in the same checkout during cleanup. If another session shares that checkout, coordinate with it first; the broker's shutdown RPC has no atomic idle check. Run the helper once per releasable Codex checkout again before closing a run or handing it back to the user, and mention any runtimes left active or skipped.

### Check Antigravity scopes

An Antigravity worker releases its processes and memory when its wrapper stops its scope, so a scope that outlives its worker is the one leak to look for. After collecting an Antigravity result, and again before closing a run or handing it back, run `systemctl --user list-units --all 'antigravity-worker-*' --no-legend`. Stop each listed scope that no running worker of yours owns, by name (`systemctl --user stop <scope>`). Then record `stopped` in the cleanup column of the task's ledger row, or `clean` when nothing was listed.

## 7. Ask the user

Ask only for decisions that are the user's: behaviour the user will see, scope and priority, spending money, anything irreversible or public (pushing, releasing, sending), and departures from the plan. Decide the rest yourself and record it in the ledger.

- Number the questions, grouped by task. For each: what it is and why it matters in one to three plain sentences, lettered options, then **Recommend x** with a one-line reason. Business words, not code names.
- Ask through the channels the user's own instructions name, for example a messaging channel plus the terminal with the same wording, first answer wins. When a second channel can answer, ask in the terminal as plain text that ends your turn, so the other answer can arrive.
- Keep every task that doesn't depend on the answer moving; mark the dependent ones held.

## 8. Report

Post one- or two-line updates at events: a task accepted or integrated, a worker escalated, a wait on a usage limit, a new question. When the run ends or pauses, report what was integrated (branches, commits), what is held and why, and the open decisions in the ask format; then set the ledger's first line to `Run: closed` if nothing is left.
