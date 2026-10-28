---
name: magicpath-proposals
description: Create design proposals for an EdgeRunner (options_ui) screen on the MagicPath canvas, grounded in DESIGN.md, the running app and the plan doc. Use when the user asks for MagicPath designs, mockups or proposals for an app screen.
---

# MagicPath proposals for the desktop app

Produce N competing, interactive design **proposals** for one options_ui screen on a MagicPath project, so the user can choose a direction before implementation. A proposal is a full-window React component that looks like the real app around the changed area, in both the light and the dark theme.

Proposals go in the **EdgeRunner** MagicPath project (<https://www.magicpath.ai/files/464418753376051200>) unless the user names another. Its approved references: the palette (`steady-space-2635`), Home (`mighty-week-1199`) and Reports Performance (`lively-town-7602`).

Load `magicpath:magicpath` (canvas mechanics) and `options_ui:impeccable` (design craft) at the start; this skill decides what they are applied to.

## 1. Pin the brief

Collect, from the user's message and the repo:

- the MagicPath project id, the target screen, and N (default 3);
- the requirement source (usually a phase in an `ib_trading/docs/*` plan) — every requirement in it becomes a checklist item each proposal must satisfy;
- the **reference surface**: an already-redesigned screen the new one must match (for Reports this is the Premium "Clear Ledger" tab);
- `options_ui/DESIGN.md`, `options_ui/PRODUCT.md`, and the screen's `options_ui/docs/*-screen.md`;
- the screen's **surface** in the window budget (step 3).

Run `bun run lint:canvas-kit` from `options_ui/`. If it reports the kit stale, run `bun run build:canvas-kit` and tell the user the kit changed (it is committed in the workspace repo). The kit, [`kit/edgerunner-tokens.css`](kit/edgerunner-tokens.css), is the app's whole token layer, light and dark, generated from `options_ui/src/css/tokens.css`.

Then grep `options_ui/src/css/styles.css` for the reference surface's selector prefix and note its real values (panel padding, borders, type sizes, breakpoints). Proposals copy those numbers, not approximations.

Run impeccable's context loader from `options_ui/` (its relative-path permission rule only matches there):
`.claude/skills/impeccable/scripts/impeccable context --target src/templates/<screen>.html`. If it is refused, say so and read DESIGN.md/PRODUCT.md directly.

Done when: you can list the requirement checklist, quote the reference surface's key CSS values, and `lint:canvas-kit` passes.

## 2. Capture the running app

With the Tauri MCP: `driver_session start`, confirm the webview is 1840×903 (`innerWidth/innerHeight`), switch to the target screen and tab, and `webview_screenshot` the current screen and the reference surface as PNGs into the scratchpad. Navigate only with tabs and menus; the dev app runs on real data, so leave switches, schedules and forms untouched.

Upload each screenshot to the canvas: `prepare_asset_upload` → `curl -X PUT -H "Content-Type: image/png" --data-binary @file '<uploadUrl>'` → `add_project_image` with the `sourceUrl`. Images all land at (0,0); leave canvas arrangement to the user.

Done when: both reference images are on the canvas and you have looked at each screenshot yourself.

## 3. Post the brief and open sessions

Send the user the project link ("Watch live: …") and a short brief: what every proposal shares with the reference surface, the screen's window budget (below), and one line per proposal naming its composition. Proposals differ in **composition** — what leads, what is side by side, what sits behind a switch — never in palette or type; those come from the kit and DESIGN.md.

Open one `start_component_code_session` per proposal in parallel (width 1840, height 903, a distinct retained `idempotencyKey`), then download each baseline into its own scratchpad directory.

**Window budget.** The window is 1840×950 (webview 1840×903), minimum 1500×800 (webview ≈753); the sidebar takes 5em (78px). Every proposal fits the default size with no page scroll; long content scrolls inside its own panel. Widths depend on the surface:

| Surface | Width | Height and notes |
|---|---|---|
| **Full-width workspace** (Home, the trade workspace) | everything right of the sidebar: ≈1762px at default, ≈1422px at minimum | The content fills the height to 16px above the window's bottom. With the right-hand column open, the table gets the width less that column. |
| **Bottom-panel inspector** (the trade inspector) | Home's right-hand column: 540px from a ≈1690px window, 480px at the minimum (the protection cards need ≈387px). Expanded, it grows leftwards to 1268px. | Runs the column's full height. Where it slides up from the bottom (App Activity) the user sets its height, so design for both a short and a tall panel. |
| **Report column** (Reports, Settings, Templates and Schedules summaries) | ≈1268px at both sizes (1300px max, 16px side padding) | Below the toolbar, ≈700px at default and ≈550px at minimum. |
| **Settings row** (inside the report column) | inside the ledger's 20px side padding: a 320px label column, a 40px gap, then ≈866px for the controls | 18px vertical padding per row. The field widths are in `docs/settings-screen.md`. |

Measure the screen's real content box in step 2 (`getBoundingClientRect()` on its content container) when its surface is new or the numbers above look off for it, and say which numbers you used.

## 4. Build

Start from [`example/`](example/) — the Performance work's shared module (app shell, toolbar, deterministic mock data, report frame, charts, period table, states) and the chosen proposal. Copy `perf-shared.*` and `kit/edgerunner-tokens.css` into each component directory and adapt the shell to the target screen; `perf-shared.css` imports the kit beside it.

Each proposal:

- renders the full shell (sidebar, top bar, tabs, toolbar) at frame size, so fit can be judged honestly;
- uses a plain CSS file beside the component with Public Sans, rather than Tailwind, and takes every colour from the kit's role and component tokens (`var(--surface)`, `var(--ink-muted)`, `var(--profit)`…), never a `--p-*` primitive or a literal, so both themes come from the same values as the app;
- renders in both themes: the shell's Design preview carries a Light/Dark switch, which sets `data-theme` on `<html>` as the app does;
- fills the remaining height with a flex column whose analysis area has a minimum height and scrolls internally;
- is fully interactive with deterministic mock data, plus a "Design preview" switcher in the top bar for loading, error, empty and edge-case states (single item, all-zero);
- satisfies every item on the step-1 checklist.

Read [`layout-gotchas.md`](layout-gotchas.md) before writing layout CSS. Package with `tar -czf x.tgz -C <dir> .`, PUT to the session's upload URL, then `submit_component_code`.

Done when: every proposal builds, every checklist item maps to something visible in each proposal, and `grep -nE '#[0-9a-fA-F]{3,8}\b|rgba?\(' <component dir>/*.css` finds nothing outside `edgerunner-tokens.css`.

## 5. Full-size check

`view_component` previews render at about 1200×630, so they cannot show fit. Run the procedure in [`full-size-check.md`](full-size-check.md) on every proposal, in both themes: one check round, one fix round, one confirming round. A submitted session is consumed, so each fix round opens new edit sessions (download the baseline, copy your files over it, upload, submit).

Done when: each proposal's report area reports `scrollHeight === clientHeight` at 1840×903, nothing overlaps, its tables open on the selected row, and you have looked at a light and a dark screenshot of it.

## 6. Hand off

Reply with: the canvas link, a share link per proposal (from `get_share_url`), a table of how the proposals differ and what each is best for, the checklist items covered, and what is mock or unverified (data, minimum-size rendering, controls that only display). When the user picks a direction, record it in auto-memory (project id, component `generatedName`, agreed refinements) so implementation can find it.

Implementation rebuilds the chosen proposal in options_ui with the app's own markup, tokens and islands. For exact measures (paddings, widths, type sizes, breakpoints), read the component's source with `get_component_code_context` or `inspect_component`; the MagicPath code itself stays on the canvas, never installed or exported into the app.
