---
name: magicpath-proposals
description: Create design proposals for a Simple Option Spreads (options_ui) screen on the MagicPath canvas, grounded in DESIGN.md, the running app and the plan doc. Use when the user asks for MagicPath designs, mockups or proposals for an app screen.
---

# MagicPath proposals for the desktop app

Produce N competing, interactive design **proposals** for one options_ui screen on a MagicPath project, so the user can choose a direction before implementation. A proposal is a full-window React component that looks like the real app around the changed area.

Load `magicpath:magicpath` (canvas mechanics) and `options_ui:impeccable` (design craft) at the start; this skill decides what they are applied to.

## 1. Pin the brief

Collect, from the user's message and the repo:

- the MagicPath project id, the target screen, and N (default 3);
- the requirement source (usually a phase in an `ib_trading/docs/*` plan) — every requirement in it becomes a checklist item each proposal must satisfy;
- the **reference surface**: an already-redesigned screen the new one must match (for Reports this is the Premium "Clear Ledger" tab);
- `options_ui/DESIGN.md`, `options_ui/PRODUCT.md`, and the screen's `options_ui/docs/*-screen.md`.

Then grep `options_ui/src/css/styles.css` for the reference surface's selector prefix and note its real values (panel padding, borders, type sizes, breakpoints). Proposals copy those numbers, not approximations.

Run impeccable's context loader from `options_ui/` (its relative-path permission rule only matches there):
`.claude/skills/impeccable/scripts/impeccable context --target src/templates/<screen>.html`. If it is refused, say so and read DESIGN.md/PRODUCT.md directly.

Done when: you can list the requirement checklist and quote the reference surface's key CSS values.

## 2. Capture the running app

With the Tauri MCP: `driver_session start`, confirm the webview is 1840×903 (`innerWidth/innerHeight`), switch to the target screen and tab, and `webview_screenshot` the current screen and the reference surface as PNGs into the scratchpad. Navigate only with tabs and menus; the dev app runs on real data, so leave switches, schedules and forms untouched.

Upload each screenshot to the canvas: `prepare_asset_upload` → `curl -X PUT -H "Content-Type: image/png" --data-binary @file '<uploadUrl>'` → `add_project_image` with the `sourceUrl`. Images all land at (0,0); leave canvas arrangement to the user.

Done when: both reference images are on the canvas and you have looked at each screenshot yourself.

## 3. Post the brief and open sessions

Send the user the project link ("Watch live: …") and a short brief: what every proposal shares with the reference surface, the window budget (below), and one line per proposal naming its composition. Proposals differ in **composition** — what leads, what is side by side, what sits behind a switch — never in palette or type; those come from DESIGN.md.

Open one `start_component_code_session` per proposal in parallel (width 1840, height 903, a distinct retained `idempotencyKey`), then download each baseline into its own scratchpad directory.

**Window budget.** The window is 1840×950 (webview 1840×903), minimum 1500×800 (webview ≈753). The Reports content column is ≈1268px wide at both sizes. Below the toolbar, a screen has ≈700px at the default size and ≈550px at the minimum. Every proposal must fit the default size with no page scroll; long content scrolls inside its own panel.

## 4. Build

Start from [`example/`](example/) — the Performance work's shared module (app shell, toolbar, deterministic mock data, report frame, charts, period table, states) and the chosen proposal. Copy `perf-shared.*` into each component directory and adapt it to the target screen; re-check its tokens against what you noted in step 1.

Each proposal:

- renders the full shell (sidebar, top bar, tabs, toolbar) at frame size, so fit can be judged honestly;
- uses a plain CSS file beside the component with the app's tokens and Public Sans, rather than Tailwind;
- fills the remaining height with a flex column whose analysis area has a minimum height and scrolls internally;
- is fully interactive with deterministic mock data, plus a "Design preview" switcher in the top bar for loading, error, empty and edge-case states (single item, all-zero);
- satisfies every item on the step-1 checklist.

Read [`layout-gotchas.md`](layout-gotchas.md) before writing layout CSS. Package with `tar -czf x.tgz -C <dir> .`, PUT to the session's upload URL, then `submit_component_code`.

Done when: every proposal builds and every checklist item maps to something visible in each proposal.

## 5. Full-size check

`view_component` previews render at about 1200×630, so they cannot show fit. Run the procedure in [`full-size-check.md`](full-size-check.md) on every proposal: one check round, one fix round, one confirming round. A submitted session is consumed, so each fix round opens new edit sessions (download the baseline, copy your files over it, upload, submit).

Done when: each proposal's report area reports `scrollHeight === clientHeight` at 1840×903, nothing overlaps, and its tables open on the selected row.

## 6. Hand off

Reply with: the canvas link, a share link per proposal (from `get_share_url`), a table of how the proposals differ and what each is best for, the checklist items covered, and what is mock or unverified (data, minimum-size rendering, controls that only display). When the user picks a direction, record it in auto-memory (project id, component `generatedName`, agreed refinements) so implementation can find it.
