pi-warden rules for the options_app workspace.

This file is judged by pi-warden (Jev) on every `write` and `edit`. Each `#` heading below is one rule.

Workspace layout: `ib_trading/` (Flask/IB backend, its own git repo) and `options_ui/` (Tauri v2 frontend,
its own git repo). The workspace root is not either repo. Repo-specific rules below name their repo in
the rule text instead of using `paths:`, so they still apply when Pi is launched from inside a child repo.

These rules are the hard boundaries; `AGENTS.md` in each repo owns the full conventions. When a rule
conflicts with a repo's `AGENTS.md`, follow `AGENTS.md` and say so.

# Never touch the developer database

DB-backed tests must use `isolated_sqlite_db` and a disposable `HOME` from
`ib_trading/tests/support/db_fixtures.py`. Never use `DB_PATH` in a test. Never run a command, script,
or test path that opens or writes the real developer SQLite database. Production event handlers invoked
outside a DB test must have the persistence boundary mocked, not merely cleaned up afterwards.

# Never invoke Python or pytest directly

Backend Python runs in the Conda env `py3.11`:
`conda run -n py3.11 python -m pytest path/to/test.py -k scenario`.
A bare `pytest`, `python`, or `python3` call is a violation (`pytest: command not found`,
`No module named pytest`, or the wrong system interpreter). Never install into or run against the global
system Python.

# Never run git or project tests from the workspace root

`ib_trading/` and `options_ui/` are separate git repositories. Run `git`, tests, and build commands from
inside the repo that owns the change, and never assume one command covers both. A backend change is
committed in `ib_trading/`; a frontend change in `options_ui/`.

# Never run a test without an outer timeout

Integration tests that drive `DefaultIronCondorStrategy._run_loop` can hang forever with no output. Run
pytest through `ib_trading/tests/run_pytest.sh` when present (it adds a process-group outer guard), or
otherwise pass an explicit outer timeout. Never launch the full suite or a broker-simulation test
(`tests/integration/test_broker_simulation_phase*.py`) without one. Prefer a focused file or `-k`
selection over the whole suite. Never start a background subagent without a bounded timeout, and never
create a git worktree unless two writers genuinely run in parallel.

# Never leave a non-daemon thread or a stale IB event binding

Background helper threads (for example `ib_trading/misc/wiretap.py`) must be daemon threads and must stop
during cleanup. Unbind IB events before rebinding or changing bindings, and during strategy cleanup. A
non-daemon thread or an unbound-but-live IB subscription is a violation.

# Never access SQLite outside the DAO layer

Database access goes through the DAO layer in `ib_trading/dao/`. Never open a SQLite connection, run raw
SQL, or bypass a DAO from a service, route, or model. Account-specific values come from `user_config`
(`ib_trading/services/user_config/`, `ib_trading/dao/user_config_dao.py`), never from ad-hoc reads.

# Never store local or naive datetimes

Use UTC (`pytz.utc`) for every stored, compared, or transmitted timestamp in `ib_trading/`. Convert to
local time only at the display boundary. A naive `datetime.now()` in persistence or strategy logic is a
violation.

# Never add a legacy or compatibility path

Until production, implement one canonical path and delete superseded paths in scope. No fallback branch,
dual-write, feature flag, or compatibility shim kept alongside the canonical implementation. Never leave
the old path behind "for safety".

# Never submit an IB order without connection and contract validation

Check `context.connected_to_broker` before any IB operation, handle disconnection gracefully, and validate
the option contract before order submission. Never place, modify, or cancel an order on an unvalidated
contract or while the broker connection is unknown.

# Never call edit without reading the exact current lines

Before every `edit`, read the file at that location. `oldText` must match exactly, including whitespace,
and be unique in the file. Never reuse a stale anchor, never guess indentation, and never issue overlapping
edits in the same call.

# Never change a UI screen's behavior without updating its reference doc

Every behavior change to a screen updates its reference doc in the same change:
`options_ui/docs/templates-screen.md`, `options_ui/docs/schedules-screen.md`, or the relevant `docs/`
reference for other screens. Cover fields, option values, visibility, validation, combinations/order, and
payload changes. This applies to small changes too.

# Never use inline handlers, eval, or default browser layout

`options_ui` respects CSP: register event listeners, never inline `onclick`-style handlers, never `eval()`.
New or restructured screen elements must add or reuse selector groups in `options_ui/src/css/styles.css`
with explicit flex layout, sizing, and field/combobox widths; relying on browser defaults is a violation.
REST calls use `fetch` with `appContext.serverUrl` and `URLSearchParams`; `src/js/backend.js` wraps Tauri
`invoke()` only.

# Never let the two frontend version files drift

`options_ui/package.json` and `options_ui/src-tauri/tauri.conf.json` versions change together. Editing one
without the other is a violation.

# Never run WSL builds or Vitest without an explicit request

On WSL, do not run `npm run build`, `npm test`, or any `npm run test:*`/Vitest command; leave test execution
to the user in Windows terminal or Git Bash. Detect WSL explicitly via `WSL_INTEROP`, `WSL_DISTRO_NAME`, or
a case-insensitive `microsoft`/`wsl` match in `uname -r`; a Linux VM or a `/home` path is not WSL, and on
native Linux focused Vitest runs are allowed.

# Never claim work is done without evidence

A "done", "fixed", or "tests pass" claim requires the actual focused test, build, or lint output behind it.
For a bug fix or behavioral change, report the reproducing red run and the passing green run. If a command
was not run, say so plainly instead of implying it passed.

# Never modify an area without consulting its reference doc

Read the repo's `AGENTS.md`, its `docs/agents/domain.md`, and the specific reference named in its task
table (e.g., `repo-map.md`, `testing.md`, the relevant `*_technical_guide.md`, or `ui-development.md`)
before changing that area. If a designated reference doc does not exist, explicitly state "No reference
doc found for [area]" in your plan before modifying files.