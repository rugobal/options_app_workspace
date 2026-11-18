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
- `runs/<date>-<slug>/ledger.md`: first line `Run: open` or `Run: closed`, then a `session started <time>` line per session continuing the run and a `context compacted` line after each compaction, then one row per task: id, title, depends on, provider and tier, worker (Claude agent ID; background Bash task ID, or on the Herdr route the worker id and its `wait` task ID; plus per attempt a companion Codex worker's job ID, a mode B worker's session ID, a Claude or DeepSeek session ID, or an Antigravity conversation ID and scope), checkout and branch, state (planned, running, checking, correcting, accepted, integrated, held), commit, and for a companion Codex worker its runtime cleanup (pending, stopped, or skipped with reason; a mode B Codex worker has none).
- `runs/<date>-<slug>/briefs/<task>.md`, and `out/<task>-<attempt>.txt` for each companion Codex attempt's output (`.json` for DeepSeek and Antigravity). On the Herdr route, mode A: `out/<task>-<attempt>.cmd` holds the worker's command and `.log` its output instead; mode B: `out/<id>.args` holds its arguments, `out/<id>.prompt` its prompt and `out/<id>/report.md` its report. Both sit beside `herdr-worker.sh`'s own files for the worker (`.exit` is its exit record).
- `runs/<date>-<slug>/workers.json`: on the Herdr route, the registry `herdr-worker.sh` keeps of the run's workers: the run's own path, each worker's pane and process group, its state and exit code. It is how a later session adopts workers still running. Read it only through `herdr-worker.sh status`, which also says what Herdr and the process table show now; a registry copied from another run is refused.

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
- what it needs from earlier tasks: commit hashes, decisions;
- for a Codex worker, companion or mode B: not to use the `codex_tui` tools, which act on the user's own Codex threads and worktrees.

A companion Codex worker in a linked worktree leaves the commit to you (a mode B Codex builder commits itself: its arguments open the Git folders it needs, [mode B](#the-herdr-route)). Its sandbox writes only the checkout and `/tmp`, and the worktree's Git metadata lives under the main repo's `.git/worktrees/`, so its `git add` fails with "Read-only file system" on `index.lock`. Its brief has it leave the changes in the checkout, write the commit message, attribution line included, to a `/tmp` file the brief names, and write its test output under `/tmp`. You commit after checking ([section 6](#6-check-a-result)), with that message, so the commit carries the worker's attribution line.

## 4. Dispatch

Each running worker has its own checkout, made by the project's worktree rules (root `AGENTS.md`).

**`workers.md` commands come first, on both routes.** When `workers.md` gives a command for a provider, that command is what either route runs, in place of the recipe below. Today both Claude kinds have one: headless `claude -p` with `CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1`, so they never go through the Agent tool. The recipes are the defaults for a provider `workers.md` gives no command for.

**Choose the route first.** When your shell has `HERDR_ENV=1` you run inside Herdr, the user's terminal workspace manager, and every worker runs in a Herdr tab the user can watch: the **Herdr route**. Otherwise, or when `herdr-worker.sh` exits 2, take the **background route**: background Bash, or the Agent tool for a Claude worker `workers.md` gives no command for. Then follow the provider's recipe for that route. Each correction or retry takes the next attempt number and keeps earlier attempts' files and IDs.

### The providers

Record each path below in `rules.md` once per run. When a provider's requirement is missing, hold its tasks and say why.

- **Claude.** Background route: the Agent tool with a fresh `general-purpose` agent (a fork ignores `model`), `model` from the pin or the tier, `effort` only when one is named, and the prompt "Read and follow the brief at `<path>`. It is your whole task; report back as it says." Record its agent ID. Herdr route: headless Claude Code, so it gets a tab: `cd "<checkout>" && claude -p --output-format stream-json --verbose --model <model> --permission-mode auto --permission-prompts none --strict-mcp-config < "<brief>"`, plus `--effort` when one is named. `--strict-mcp-config` keeps MCP servers such as a messaging bot with you. It commits itself, like a DeepSeek worker; record the `session_id` from its result.
- **Codex.** Find the `codex@openai-codex` entry in `~/.claude/plugins/installed_plugins.json` that matches this session's scope and project, append `scripts/codex-companion.mjs` to its `installPath`, check the file exists, and record it as `<companion>`. Resolve [scripts/cleanup-codex-companion.py](scripts/cleanup-codex-companion.py) relative to this skill's directory and record it as `<cleanup>`, and the folder [scripts/codex-no-mcp](scripts/codex-no-mcp/) as `<no-mcp>`. Every `node "<companion>"` call, a command from `workers.md` included, runs with `PATH="<no-mcp>:$PATH"` in front ([No MCP servers](#no-mcp-servers-for-codex)); `cancel` too, as it starts an app server of its own when the checkout has none. The command, with the effort from the pin or tier:

  ```
  PATH="<no-mcp>:$PATH" node "<companion>" task --fresh --write --effort <effort> --prompt-file "<brief>" --cwd "<checkout>"
  ```

  Leave off the companion's own `--background` flag, so the process ends when the task does. Right after dispatch, record the attempt's job ID (`task-…`): the checkout's newest job, from `node "<companion>" status --cwd "<checkout>" --json | jq -r '[.running[]?, .latestFinished, .recent[]?] | map(select(. != null)) | max_by(.createdAt) | .id'` (a checkout has one Codex worker at a time). If its `createdAt` is from before the dispatch, the job is not listed yet: look again at the next wake-up. The process's exit status is not the result: read the job's with `result` ([section 6](#6-check-a-result)). This is a **companion worker**, the Codex worker of the background route and of mode A; mode B runs the `codex` CLI itself, with no companion.
- **DeepSeek.** Headless Claude Code on DeepSeek through OpenRouter, via [scripts/deepseek-worker.sh](scripts/deepseek-worker.sh), recorded as `<deepseek>`. It reads the OpenRouter key from `OPENROUTER_API_KEY` or `~/.config/openrouter/api_key`. The command, with the effort from the pin or tier and the compact window from `workers.md` (default 300000 tokens), plus `--stream` on the Herdr route so the tab shows its progress:

  ```
  "<deepseek>" --brief "<brief>" --cwd "<checkout>" --effort <effort> --compact-window <tokens>
  ```

  It has the full Claude Code toolset and commits itself, like a Claude worker. Record the `session_id` of its result object. Its `total_cost_usd` is Claude Code's guess at Claude prices for an unknown model, about six times the real figure; the real spend is the change in `usage` from `GET https://openrouter.ai/api/v1/key` with the key as Bearer token.
- **Antigravity.** Google's Gemini through the Antigravity CLI (`agy`) in print mode, via [scripts/antigravity-worker.sh](scripts/antigravity-worker.sh), recorded as `<antigravity>`. It needs `agy` signed in (`agy models` lists the model ids). The checkout must sit inside agy's trusted workspaces (`~/.gemini/antigravity-cli/settings.json`): outside them agy quietly works in its own scratch folder, so the wrapper refuses. The command, with the model and effort from the pin or tier (the wrapper's defaults are the frontier pair, `gemini-4-argon` at `high`; each model offers only some efforts, as `agy models` lists):

  ```
  "<antigravity>" --brief "<brief>" --cwd "<checkout>" --model <model> --effort <effort>
  ```

  Record the systemd scope named on the first line of its stderr and the `conversation_id` of its result. The brief goes in as the prompt itself, so keep it under 120000 characters. The worker runs with every tool approved and commits itself. On Argon it takes the same frontier work as Claude and Codex workers. The wrapper's `--timeout` (default `3h`) is agy's own print-mode limit. agy and every process the worker starts run in that scope, and the wrapper stops the scope when agy exits or the wrapper is stopped, so nothing the worker started outlives it and its memory is released. Docker containers belong to dockerd, outside the scope: tests remove their own.

### No MCP servers for Codex

Codex workers run without the user's MCP servers and connectors (the owner's decision, 2026-11-18): Codex's sandbox holds shell commands only, and a server runs outside it with the user's network and files. [scripts/codex-no-mcp/no-mcp.args](scripts/codex-no-mcp/no-mcp.args) is the list of `-c` pairs that turn them off, one argument per line. It names the servers and plugins of the user's Codex config, so one added there later needs its own lines in that file.

- **Companion workers** get the list from `<no-mcp>/codex`, which the `PATH` prefix puts before the real `codex`: the companion starts `codex app-server` from `PATH`, and the wrapper runs the real one with the list's pairs in front. A checkout's app server starts with its first task and keeps its arguments until you release that checkout ([section 6](#release-finished-codex-runtimes)), so release a checkout whose broker started without the prefix, or with another list, before dispatching there. A few seconds after the first companion dispatch in each checkout, read that checkout's app server arguments; this takes no model turn:

  ```
  for p in $(pgrep -f ' app-server$'); do [ "$(readlink /proc/$p/cwd)" = "<checkout>" ] && tr '\0' '\n' < /proc/$p/cmdline; done
  ```

  It prints a `codex` path, the list's lines, then `app-server`. When `app-server` follows the path directly, or nothing prints twice a few seconds apart while the task runs, cancel the job, release the checkout and stop for the user. The arguments can't show a server that the checkout's own `.codex/config.toml` adds, so before the first companion dispatch in a checkout, look for that file, tracked or not: when `grep -s -E 'mcp_servers|plugins' "<checkout>/.codex/config.toml"` prints a line, stop for the user.
- **Mode B workers** take the list at the end of their args file, and `mcp` checks each one before its first prompt ([mode B](#the-herdr-route), step 4).
- **Giving a server back.** A task that needs one of these servers gets it back, limited to the tools it needs, in a copy of the list: `cp "<no-mcp>/no-mcp.args" "<run>/out/<task>.no-mcp.args"`, then edit the copy. Every value keeps its own `-c` line before it, and every plugin entry stays inside the one `plugins=` value. The restored server gets three settings, because the user's config can approve a whole server or single tools and the copy's values override it:
  - `enabled_tools`, naming only the task's tools;
  - `default_tools_approval_mode="auto"`, the setting that approves nothing by itself: under `never`, Codex runs a tool only when it is marked read-only, or marked both not destructive and closed-world;
  - an `approval_mode` for each of those tools: `"auto"`, or `"approve"` for a tool the task needs that Codex would refuse. Never approve the whole server.

  A config server: its `enabled=false` value becomes the three values. The copy for `tauri` with one tool, `<tool>` the only part to fill in:

  ```
  -c
  plugins={"mongodb@mongodb-plugins"={enabled=false},"unified-computer-use@openai-bundled"={enabled=false}}
  -c
  mcp_servers.tauri.enabled_tools=["<tool>"]
  -c
  mcp_servers.tauri.default_tools_approval_mode="auto"
  -c
  mcp_servers.tauri.tools.<tool>.approval_mode="auto"
  -c
  mcp_servers.node_repl.enabled=false
  -c
  features.apps=false
  ```

  A plugin's server: first find every server the plugin supplies, with no model turn. Run `xargs -d '\n' -a "<file>" codex mcp list --json` on the list and on a scratch copy whose entry for the plugin reads `{enabled=true}`; the names only the scratch run shows are the plugin's servers. Its entry in the task's copy then reads `{mcp_servers={<server>={<the three values>},<other server>={enabled=false}}}`, one `enabled=false` entry for each other server it supplies. The copy for `mongodb`, the only server `mongodb@mongodb-plugins` supplies (checked 2026-11-18):

  ```
  -c
  plugins={"mongodb@mongodb-plugins"={mcp_servers={mongodb={enabled_tools=["<tool>"],default_tools_approval_mode="auto",tools={<tool>={approval_mode="auto"}}}}},"unified-computer-use@openai-bundled"={enabled=false}}
  -c
  mcp_servers.tauri.enabled=false
  -c
  mcp_servers.node_repl.enabled=false
  -c
  features.apps=false
  ```

  Before the dispatch, from the checkout: `xargs -d '\n' -a "<copy>" codex mcp get <server>` (plain: `--json` leaves out the approval mode) must show `enabled_tools` with only the task's tools and `default_tools_approval_mode: auto`, and `grep -n approval_mode ~/.codex/config.toml` shows what the user's config approves, which the copy's values replace for the tools it gives back; neither takes a model turn. A worker given a tool back reaches whatever that tool reaches, outside its sandbox. A companion worker takes the copy with `CODEX_NO_MCP_ARGS="<copy>"` in front of every dispatch, its resume included, in a checkout released just before; release it again before the next task there. A mode B worker's args end with the copy in place of the list, and its `mcp` list is the final proof.
- **`codex_tui`**, the Codex screen's own tools on the user's Codex threads and worktrees, has no off switch. Mode B workers have it, and every Codex brief says not to use it ([section 3](#3-brief-a-worker)).

### The background route

Run the provider's command in background Bash (`run_in_background`), with absolute paths, and record Bash's background task ID; its exit wakes you. Codex: `> "<run>/out/<task>-<attempt>.txt" 2>&1`. Headless Claude (`--output-format json`), DeepSeek and Antigravity: `> "<run>/out/<task>-<attempt>.json" 2> "<run>/out/<task>-<attempt>.err"`; the `.json` file is the result object.

### The Herdr route

Every worker runs through [scripts/herdr-worker.sh](scripts/herdr-worker.sh), recorded as `<herdr-worker>`. Its header lists every subcommand, its JSON and its exit codes; every call prints one JSON object. The user sees one workspace per run, `w-<run slug>`, holding one tab per worker labelled `<task> <provider> <effort>` (`T41 codex xhigh`), which shows `working` and then `done`. A worker in a tab outlives your session and dies only with the Herdr server or its tab, so while any run has a worker in a tab, leave the server alone: no `herdr update`, no server stop or restart.

**Mode A, the default: the headless worker in a tab.** Every provider.

1. Write the provider's command (from `workers.md` when it gives one), without output redirections, to `<run>/out/<task>-<attempt>.cmd`. For headless Claude, switch `--output-format json` to `stream-json --verbose`.
2. `"<herdr-worker>" launch --run "<run>" --id <task>-<attempt> --label "<label>" --cwd "<checkout>" --harness claude|codex|deepseek|agy --cmd-file "<run>/out/<task>-<attempt>.cmd"`. Output goes to `out/<id>.log`, stderr to `out/<id>.err` (Codex's goes into the log). For Codex, record the job ID now, as above.
3. In background Bash with `timeout` 7200000: `"<herdr-worker>" wait --run "<run>" --id <id>`. Record the id and the wait's task ID. Its exit wakes you:
   - 0: the worker ended by itself; its own status is `exit_code`.
   - 3: the wait's own limit, just under two hours, passed. The worker is unaffected; start the wait again.
   - 4: the worker was stopped: its tab closed, Ctrl+C in it, or `close`. Treat it as a stall ([section 5](#5-nudge)).
   - 7: the worker was lost: what supervised it died, so its exit code is unknown. Check its checkout and log, then treat it as a stall.

   One known limit: a worker whose supervisor was killed by hand and whose tab was then closed while no `wait` ran keeps running, unsupervised, until the next `wait` or `close` on it stops it. `status` shows it with `supervisor_alive` and `pane_present` both false; `close` it.

**Mode B, on request: an interactive agent the user can steer.** Choose it when the user may want to watch a worker and type into it. It takes Claude (`--kind claude`), Codex (`--kind codex`), DeepSeek through Pi (`--kind pi`) and Antigravity (`--kind agy`).

1. Write the agent's arguments to `<run>/out/<id>.args`, **one argument per line, passed as is**: write exactly the characters the program should receive. Shell quotes are not needed and are not removed, and nothing is expanded; empty lines are skipped. A flag and its value are two lines.
   - Claude: `--model`, `<model>`, `--effort`, `<effort>` (when one is named), `--permission-mode`, `auto`, `--strict-mcp-config`, plus `--advisor`, `<model>` when `workers.md` names one. Code Mode and any other variable the agent reads at start go to `start` as `--env CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1`.
   - Codex: a builder or a read-only reviewer, `<model>` and `<effort>` from the pin or tier and every path absolute. Its report goes in a folder of its own, `<run>/out/<id>/`. Builder, whose shell commands write in its checkout, the Git folders listed and its report folder:

     ```
     -m
     <model>
     -c
     model_reasoning_effort=<effort>
     --ask-for-approval
     never
     --sandbox
     workspace-write
     --add-dir
     <git dir>
     --add-dir
     <common git dir>/objects
     --add-dir
     <common git dir>/refs
     --add-dir
     <common git dir>/logs
     --add-dir
     <run>/out/<id>
     ```

     `<git dir>` is the worktree's own Git folder, `git -C "<checkout>" rev-parse --path-format=absolute --git-dir`, and `<common git dir>` the same with `--git-common-dir`. With those writable the builder runs `git add` and `git commit` in a linked worktree and commits itself, like a Claude worker. Its shell commands can't write the repo's config or hooks and have no network, as in mode A. Read-only reviewer, its TOML quotes part of the values:

     ```
     -m
     <model>
     -c
     model_reasoning_effort=<effort>
     --ask-for-approval
     never
     -c
     default_permissions="reviewer"
     -c
     permissions.reviewer.filesystem={":root"="read","<run>/out/<id>"="write"}
     ```

     Its shell commands read everything and write only in `<run>/out/<id>`. The profile is its whole sandbox: a `--sandbox` flag would replace it.

     Both end with the no-MCP list ([No MCP servers](#no-mcp-servers-for-codex)), or a give-back task's copy of it: `{ echo; cat "<no-mcp>/no-mcp.args"; } >> "<run>/out/<id>.args"`. The empty line `echo` adds is skipped, and it keeps the list's first line off a last line written without its newline.
   - Pi: `--model`, `openrouter/<the DeepSeek model>` (`openrouter/deepseek/deepseek-v4.1-flash-1017` unless `workers.md` names another), `--thinking`, `<effort>`. Pi starts with the user's own extensions, packages, skills and MCP servers, as the user's own Pi sessions do, because the linters and other tools help the worker (the owner's decision, 2026-11-18); Herdr's state extension is among them, which is how Herdr tracks the agent's state. A Pi worker can therefore reach what those extensions reach, for example the user's Telegram ask extension, so its brief says not to contact the user and to put questions in its report.
   - Antigravity: `--model`, `<model>`, `--effort`, `<effort>`; the checkout must be trusted, as above.
2. `"<herdr-worker>" start --run "<run>" --id <id> --label "<label>" --cwd "<checkout>" --kind claude|codex|pi|agy --args-file "<run>/out/<id>.args" --report "<run>/out/<id>/report.md"`, plus the `--env` items; `start` creates the report's folder. It returns when the agent is ready (0), at a dialog (5, the screen in `screen`), or not ready yet (3: run `"<herdr-worker>" ready --run "<run>" --id <id>`, which exits the same way).
3. On 5: read `screen`. Only in a checkout you made, answer these dialogs with `"<herdr-worker>" keys --run "<run>" --id <id> --keys "<keys>"` (Herdr key names):
   - Codex, "Trust this folder?": `enter` (Trust and continue). Codex trusts the repository root, for a linked worktree its main repo, and saves that in `~/.codex/config.toml`, so worktrees of a trusted repo never show it.
   - Codex, "Hooks need review": `esc`. Codex continues this session without the new or changed hooks and saves nothing. It shows whenever a hook is new or changed to Codex, so in every new worktree of a repo that tracks `.codex/hooks.json`.
   - Claude, Pi or Antigravity, its folder-trust dialog: the keys for its trust choice, read from `screen` (such as `down enter`).

   Every other dialog is the user's to answer in the tab. Then `ready` again. Send the first prompt only after `start` or `ready` exits 0, and for Codex after step 4.
4. Codex: before its first prompt, check every worker's MCP servers with `"<herdr-worker>" mcp --run "<run>" --id <id>`. It sends `/mcp verbose` only to an empty composer and reads the list Codex prints; it opens no turn and leaves the composer empty. The expected list comes from the worker's args: `connected` holds `codex_tui` (Codex's own tools, no off switch) and each server the args give back, listing exactly that server's `enabled_tools`, and every other server in `servers` reads `disabled`.
   - 0: compare the result with the expected list. Any other server or tool, or another status (a server starting, failed or waiting for a sign-in): close the worker and stop for the user.
   - 1 (`mcp_unreadable`): no complete new list appeared. Close the worker and stop for the user.
   - 5 or 3: nothing was sent. A dialog (5): answer it as in step 3 or leave it to the user. A draft or a menu (3) is the user's. Run `ready` until it exits 0, then `mcp` again. 4: treat it as a stall.
5. Write "Read and follow the brief at `<brief>`. Write your report to `<run>/out/<id>/report.md`, then end your turn." to `<run>/out/<id>.prompt`. In background Bash with `timeout` 7200000: `"<herdr-worker>" prompt --run "<run>" --id <id> --text-file "<run>/out/<id>.prompt"`. Each prompt is one turn; record `session_id` from its JSON once it is set. A Codex worker's id is verified as its own: Herdr's, or its checkout's only Codex session written since it started; `session_ambiguous: true` means two Codex agents wrote in that checkout, and the id stays unset. Its exit wakes you:
   - 0: the agent finished its turn and wrote the report during it (`report_turn` equals `turn`). A report from an earlier turn or attempt never counts.
   - 5 with `delivered: false`: the agent was at a dialog, so the prompt was refused and no turn opened. Answer the dialog as in step 3 or leave it to the user, run `ready` until it exits 0, then send the same prompt again. `wait` refuses here (64 `not_delivered`).
   - 5 with `delivered: true`: the agent waits at a dialog mid-turn. Answer it as in step 3, then `"<herdr-worker>" wait --run "<run>" --id <id>` in background Bash, which exits like `prompt`. `wait` is only for a delivered prompt.
   - 6: the agent ended its turn without writing the report. Read `screen`, then `prompt` again with what remains.
   - 3 with `delivered: false`: nothing was sent and no turn opened, because the agent's input was not its empty prompt (for Codex: a draft in the composer, the history search, a menu, or a pane too narrow for its footer hints; the screen is in `screen`). What is on screen is the user's: run `ready` until it exits 0, then send the same prompt again.
   - 3 with `delivered: true`: time is up and the turn is still going: `wait` again. 4: the agent or its tab is gone; treat it as a stall.

## 5. Nudge

- **Inspect a companion Codex worker** for a suspected stall: `node "<companion>" status "<job-id>" --cwd "<checkout>" --json`. When a Claude session ends normally, the plugin stops only the Codex jobs in the session's own working directory. A worker in another checkout (every worktree worker), or any worker after a crash, can still be running. Look it up by its recorded ID, which also finds earlier sessions' jobs, then cancel it or let it finish.
- **Stopped without its result** (out of turns, a question its brief answers, half done): resume it with what remains. Claude: SendMessage to its agent ID (load the tool through ToolSearch if it is deferred); it keeps its context. A companion Codex worker: replace `--fresh` with `--resume-last` in the dispatch command and use a brief of what remains, with the same `--cwd`. It resumes this session's latest task thread there and refuses while one is running. Headless Claude and DeepSeek: rerun the dispatch command with `--resume <session_id>`, a brief of what remains, and the same `--cwd`. Antigravity: the same, with `--resume <conversation_id>`. For a worker from an earlier session, start fresh with a brief that continues from the branch's state. On the Herdr route, a resume or rerun is a new `launch` with the next attempt number and the changed command, after you `close` the earlier attempt; a headless Claude worker resumes with `--resume <session_id>` in the same checkout, and a mode B worker takes another `prompt`. A mode B Codex worker whose tab is gone resumes with a new `start` whose args file is the line `resume`, the line with its verified `session_id`, then its whole recipe from `-m` on; the conversation continues there. Without a verified id, start fresh with a brief of what remains.
- **Usage limit**: wait for the reset, with a background Bash `sleep` that wakes you then, or switch provider when the mode allows (`mixed`, `auto`). In `claude` or `codex` mode, tell the user what is waiting and until when.
- **Stall or provider error** (a crash, network failure, garbled output, or a worker far past its expected time with no new output): stop it and rerun with a fresh worker on the same tier. For a companion Codex worker, cancel with `PATH="<no-mcp>:$PATH" node "<companion>" cancel "<job-id>" --cwd "<checkout>" --json`: stopping Bash alone can leave the shared Codex background process working in the checkout. Confirm with `status` before replacing it. For DeepSeek, stopping the background Bash task stops the worker. For Antigravity, stopping it makes the wrapper stop its scope; when the wrapper was killed outright, stop the scope by its recorded name: `systemctl --user stop <scope>`. On the Herdr route, stopping the `wait` leaves the worker running; `"<herdr-worker>" close --run "<run>" --id <id>` stops it and closes its pane (for a companion Codex worker, after the `cancel`).
- **Fails its checks after one correction round**: a fresh worker one tier up, given the brief plus what went wrong. Already at frontier: a fresh frontier worker on the other provider when the mode allows; otherwise the user decides.

## 6. Check a result

Read DeepSeek's output JSON first: `is_error` and `result`. Read Antigravity's first: `status` (`SUCCESS` or `ERROR`), `error` and `response`. Read a companion Codex worker's launch output first. If its report is missing, retrieve the stored report or failure with `node "<companion>" result "<job-id>" --cwd "<checkout>" --json`. If `status` still lists the job as running after its process ended (the Bash exit, or `wait` on the Herdr route), the companion lost the turn: treat it as a stall ([section 5](#5-nudge)), and cancel the job first, since the cleanup helper skips a checkout with a job it thinks is running.

On the Herdr route, the output sits in `out/<id>.log`. For Claude and DeepSeek workers its last line (`tail -n 1`) is that JSON object, with `is_error`, `result` and `session_id`. A companion Codex worker's log holds what its `.txt` would, Antigravity's is its `.json`, and a mode B worker's report is its `out/<id>/report.md`. A mode A tab shows its worker's state, so keep it true:

- while you check a worker: `"<herdr-worker>" state --run "<run>" --id <id> --state working --message checking`;
- while a worker's question waits for the user: `--state blocked --message "<question number>"`.

You are the reviewer. The worker's report is a claim; the checkout is the evidence. A worker's own model is never the only check of its work. In the worker's checkout, check:

- the branch and commit: the brief's branch, a clean tree, the briefed commit and message (a companion Codex worker in a linked worktree: its changes in the checkout and its message file, committed by you once every check passes);
- the diff against the brief: read every hunk; each goal met, nothing outside the scope, no stray churn (formatting, lockfiles, debug leftovers, unrelated files);
- the tests: the named tests exist and exercise the change (read them), and the focused commands pass when you rerun them yourself on the brief's same file list, since a worker's sandbox can differ from yours (Codex's has no network, and in a linked worktree it blocks asyncio's socket-pair wakeup in some tests). For a Codex result, your rerun is the one that counts; a sandbox-only test workaround the worker needed goes in the task's ledger row. The whole suite runs once, when every task of the spec is done;
- the project's rules and the plan's progress-tracking rule;
- each small decision the worker recorded: agree, or turn it into a question for the user.

Any review the project's route requires for this work also runs, as a worker's task. Routine defects go back to the same worker as a numbered list; material ones go to the user. Then integrate and update the ledger. After each integration, and after each compaction, check the handoff triggers: when one holds, follow the [orchestrator-handoff](../orchestrator-handoff/SKILL.md) skill instead of dispatching again. Otherwise dispatch whatever the integration unblocked.

On the Herdr route, close an accepted task's worker: `"<herdr-worker>" close --run "<run>" --id <id>`. It marks the worker `closing`, closes the worker's own pane and stops the worker (mode A: its process group, checked gone; mode B: through Herdr only, never by signal), and only then marks it `closed`. An exit 1 (`worker_survived`, or a Herdr error) leaves it `closing`; `close` it again. A pane the user split off beside it stays. A companion Codex worker's runtime outlives its pane, so the cleanup below still runs: `close` gives it as `codex_cleanup.argv`, the helper's argument list. A mode B Codex worker ends with its pane, its MCP helpers and sandboxed commands with it. When the run closes, `close --all` closes every worker's pane. Herdr removes a tab with its last pane and the workspace with its last tab, so panes the user opened in the run's workspace keep it open; the JSON lists them as `panes_not_in_registry`.

Done when: every hunk is read, the focused tests pass on your rerun, the ledger row says accepted, and on the Herdr route the task's worker is closed.

### Release finished Codex runtimes

The parent conductor owns this cleanup. Companion 1.0.6 can keep completed threads and their MCP/REPL helpers loaded after the worker exits. A worker's final answer, a Bash exit, or `cancel` alone does not release the shared broker.

After collecting the result and accepting a companion Codex worker's task, clean its checkout before dispatching more work and before removing its worktree; a worktree already removed is cleaned by its old path. Also clean a cancelled or failed attempt once its failure is recorded and you have decided to replace it with a fresh worker. Keep the runtime while planning to use `--resume-last`, while a correction or approval is pending, or when the user wants a background service to keep running.

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
