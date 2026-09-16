# Options App Workspace

Workspace-level configuration for the options trading app.

The actual application code lives in two independent repositories that should be cloned into this directory separately:

- `ib_trading/` — Flask/Interactive Brokers backend
- `options_ui/` — Tauri desktop frontend

This repository tracks shared workspace files such as:

- `AGENTS.md` — parent-level guidance for coding agents
- `.agents/` and `skills-lock.json` — project agent skills/configuration
- `.claude/` — Claude-compatible symlinks to the shared agent skills
- `.tmuxp.yaml` — tmuxp workspace layout
- `.vscode/` — workspace editor settings, if useful

## Setup

Clone this workspace repo, then clone the app repos inside it:

```bash
git clone <workspace-repo-url> options_app
cd options_app

git clone <ib_trading-repo-url> ib_trading
git clone <options_ui-repo-url> options_ui
```

Start the tmux workspace with:

```bash
tmuxp load .tmuxp.yaml
```

## Notes

`ib_trading/` and `options_ui/` are intentionally ignored by this repo because they are managed as separate Git repositories.
