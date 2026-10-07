# Full-size check

Proves each proposal fits the app's default webview (1840×903). Use Claude in Chrome. If several browsers are connected, ask the user which one to use.

## Procedure

1. Get the proposal's link with `get_share_url` and open it in a new tab. The design renders inside an iframe. Resizing the browser window usually does nothing, so force the app root to the window size instead. Wait for the root to exist first:

   ```js
   const doc = () => document.querySelector('iframe')?.contentWindow?.document;
   for (let i = 0; i < 30 && !doc()?.querySelector('.pf-app'); i++) await new Promise(r => setTimeout(r, 500));
   const d = doc();
   Object.assign(d.querySelector('.pf-app').style, { inset: 'auto', left: '0', top: '0', width: '1840px', height: '903px' });
   await new Promise(r => setTimeout(r, 700));
   const rep = d.querySelector('.pf-report');
   ({ scrollH: rep.scrollHeight, clientH: rep.clientHeight });
   ```

   `scrollH` must equal `clientH`. If it doesn't, list each child of `.pf-report` with its height and margins to find the overflow.

2. Take a `zoom` screenshot of region `[0, 0, 1840, 903]` and look at it. Check that nothing overlaps, the footnote is visible, charts have usable height, and tables show enough rows to read.

3. Exercise the interactions that change layout: the longest date preset, each grouping, the Chart/Table switch, and the Design preview states. Check that the selected table row is inside the scroll box after a switch.

4. Close the tab when done.

## Pitfalls

- A tab Chrome considers hidden (`document.visibilityState === 'hidden'`) runs no `ResizeObserver` or `requestAnimationFrame` callbacks. Charts then don't resize and rows don't reveal. Take a screenshot to force a frame before you conclude anything is broken.
- After a navigation the page loads asynchronously, so poll for elements rather than reading them straight away.
- The minimum window (≈753px tall) can't be emulated this way, because media queries follow the real viewport. Report the minimum size as unverified unless you can actually resize the browser.
