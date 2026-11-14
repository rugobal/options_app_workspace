# Options trading workspace

Two independent repositories:

- `ib_trading/` — Flask/Interactive Brokers backend.
- `options_ui/` — Tauri desktop frontend.

Before working in a repo, read its `AGENTS.md`. For cross-repo changes, read both.
`AGENTS.md` is canonical; each repo's `CLAUDE.md` is a symlink to it.

Until the first release (`ib_trading/docs/edgerunner_release_roadmap.md`), EdgeRunner is a new product built from scratch in both repos: build only the new path, delete what it replaces, keep no old path, compatibility code, alias, fallback, shim or backfill for older code or data, and when in doubt simplify. Old trades in the development database may be deleted when a change can't carry them, so a migration never carries old rows: back the database up first and get the owner's OK before deleting.

## Worktrees

Create worktrees in the sibling `options_app-worktrees/` directory, grouped by repo:
`options_app-worktrees/<repo>/<worktree-name>`, for example
`git -C options_ui worktree add ../../options_app-worktrees/options_ui/quick-trade-launcher -b feat/quick-trade-launcher`.
