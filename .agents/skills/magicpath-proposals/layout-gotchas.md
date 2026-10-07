# Layout gotchas for full-window proposals

Each of these broke a proposal at real size during the Performance report work. The fixes are already in [`example/perf-shared.css`](example/perf-shared.css) and [`example/perf-shared.tsx`](example/perf-shared.tsx); keep them when adapting.

## Fitting the height

- **Flex chain.** Every ancestor between `.pf-column` and a scrolling table or chart needs `flex: 1; min-height: 0`, or content grows the page instead of scrolling inside its panel.
- **Grids.** A CSS grid that fills a flex slot needs `grid-template-rows: minmax(0, 1fr)`. Without it the row sizes to its content and the whole report scrolls.
- **Floor.** Give the analysis slot `flex: 1 0 300px; min-height: 300px` and let `.pf-report` scroll as a whole. Below that height the report scrolls; panels never collapse or overlap the footnote.
- **Contained panels.** Panels are `overflow: hidden; position: relative`. The `position` matters: a visually hidden table `<caption>` (absolutely positioned) otherwise escapes the clip and inflates the report's `scrollHeight`, leaving a phantom scrollbar.
- **Short windows.** Add a `max-height: 850px` block that tightens margins and padding, matching Premium's compact rules.

## Text and spacing

- `.pf-app p { margin: 0 }` outranks single-class rules. Give paragraph margins as `.pf-app .pf-evidence`, not `.pf-evidence`.
- Every line of explanatory text above a chart costs chart height. Put chart names inside the plot, legends in the panel's title row, and long explanations in the "How the report works" drawer.

## Charts and tables

- **Measuring.** Size SVG charts from a `ResizeObserver` attached through a callback ref (`useElementSize`), so a chart that unmounts and remounts (a Chart/Table switch) is measured again.
- **Scrolling a row into view.** Set the scroll container's `scrollTop` yourself, allowing for the sticky header and footer. `scrollIntoView` also scrolls the window and cuts off the app's top bar.
- **First reveal.** A newly mounted table only becomes scrollable once flex layout constrains it, so reveal the selected row from a `ResizeObserver` on the scroll box, once.
- **Contrast on tinted rows.** Profit teal and loss red fall below 4.5:1 on a selected-row tint. Darken the text on that row (`--pos-on-tint`, `--neg-on-tint`) rather than lightening the tint.
- **Zero values.** Draw a short neutral marker on the baseline, not a bar of fabricated length. All-zero data gets a symmetric ±$100 axis so it still renders.
