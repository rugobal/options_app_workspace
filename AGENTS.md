# Options trading workspace

Two independent repositories:

- `ib_trading/` — Flask/Interactive Brokers backend.
- `options_ui/` — Tauri desktop frontend.

Before working in a repo, read its `AGENTS.md`. For cross-repo changes, read both.
`AGENTS.md` is canonical; each repo's `CLAUDE.md` is a symlink to it.

## Worktrees

Create worktrees in the sibling `options_app-worktrees/` directory, grouped by repo:
`options_app-worktrees/<repo>/<worktree-name>`, for example
`git -C options_ui worktree add ../../options_app-worktrees/options_ui/quick-trade-launcher -b feat/quick-trade-launcher`.
