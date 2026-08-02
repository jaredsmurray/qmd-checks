---
name: slide-render-check
description: >
  Verify that a rendered Quarto revealjs deck in slides/ actually displays correctly — equations
  that silently lost their middle, tables that lost rows, slides clipped past 720px, chunk options
  leaking into later output. Apply after rendering any slides/*.qmd and before publishing, and
  whenever someone reports that a deck "looks wrong," has a broken equation or table, or shows
  unexpected numeric formatting. Carries the browser audit loop and the failure patterns this
  project has actually hit, several of which are invisible in the .qmd source and produce no
  render warning. Companion to slide-style, which governs what a slide says rather than whether
  it renders.
---

# Checking that a deck renders correctly

`slide-style` decides what belongs on a slide. This skill checks whether the file you wrote is
what the audience sees. The two failure modes it exists for are silent: **Quarto exits 0, emits no
warning, and produces a deck with a mangled equation or a table missing half its rows.** Never
treat "rendered cleanly" as evidence that a deck is correct.

## Before anything else: make sure you're looking at the current render

Two traps, both of which have cost real time on this project.

**Is the HTML newer than the source?** `ls -l deck.qmd deck.html`. If someone reports a bug,
confirm the HTML postdates the last edit before investigating.

**Is the browser showing the current HTML?** The preview pane aggressively caches `file://`
snapshots. `navigate` to the same path, a `?v=2` query string, `location.reload(true)`, and
`preview_start` have all returned a *stale page* here; one tab kept serving a previously-loaded
chapter through repeated `navigate` calls. Only `tabs_create` followed by `navigate` reliably
loads fresh content, and even that occasionally fails to attach.

So: **create a new tab for every render, and assert what loaded before trusting any measurement** —
`location.pathname` plus a string you know is new. A measurement taken against last render's HTML
is worse than no measurement, because it reads as a passing check.

## Wait for MathJax and fonts before measuring anything

In a freshly opened tab, MathJax has often not typeset yet. Two consequences, and both have
produced false conclusions here:

- **Untypeset math looks like broken math.** Raw `\(\$10{,}103 + 280.37 \times 2000\)` on screen
  can mean MathJax hasn't run — not that your escaping is wrong. A correct fix was nearly reverted
  on this evidence. Check `document.querySelectorAll('span.math')` against how many contain an
  `mjx-container`: if *every* span is untypeset, the problem is timing, not content.
- **Heights are wrong until math and webfonts settle.** The same slide measured 744px typeset and
  under 720 untypeset. Measuring early silently passes slides that will clip in the room.

Always `await MathJax.typesetPromise()` and `await document.fonts.ready` first. `audit.js` does.

## The audit loop

Set the viewport to 1280×800 (the deck is 1280×720; the window needs the extra chrome). Then for
each slide: `Reveal.slide(h, v, 99)` — the 99 reveals all fragments — then `Reveal.layout()`, then
measure. **`Reveal.layout()` is not optional**: `r-stretch` figures compute to height 0 at the
wrong viewport, and every figure slide then falsely reports as fitting.

Run `audit.js` in the console for the programmatic sweep, then screenshot the slides it flags and
*read them*. The sweep localizes problems; only your eyes confirm one. Screenshot anything you
changed, whether or not it was flagged.

## Failure patterns seen on this project

### A literal `$` swallows the next math span

`scales::dollar()` emits a bare `$`. Pandoc reads that as opening a math span and scans forward to
the next `$`, consuming everything between — **including table cell and row delimiters**. There is
no warning. Two symptoms, neither of which points at the cause:

- An equation renders with its middle gone. `$`r comma(b0)` + `r number(b1)` \times 2000 \approx `r dollar(y_pred)`$`
  displayed as `$10,103 + 280.37 571, 000` — the `\times 2000 \approx` vanished.
- **A `kable()` table silently loses rows.** A 7-row table rendered 4 rows; a 3-row table rendered
  1, dropping the R² row entirely, with debris like `275,000||RSE$` in a surviving cell.

The fix is to escape the dollar rather than avoid it. `slides/_setup.R` provides both helpers:

```r
math_usd(x)   # "\$571{,}000" — escaped $, braced comma; use inside $...$ and $$...$$
cell_usd(x)   # "\$275,015"   — escaped $; use in kable cells that share a table with $...$ math
```

The braced comma in `math_usd()` also fixes a cosmetic bug: MathJax sets a bare `571,000` as
`571, 000`, spacing the comma as punctuation. The book chapters carry their own copy of
`math_usd()` in each setup chunk (`regression_01_intro.qmd`, `regression_03_model.qmd`), since
they don't share `_setup.R`.

`dollar()` in ordinary prose with no math nearby is fine and stays. The bug needs a `$…$` span in
the same block.

### Chunk options leak into every later chunk

`options(scipen = 999)` in a mid-deck chunk printed a p-value to 200+ digits on its own slide and
then reformatted every *later* `summary()` in the deck to `p-value: < 0.00000000000000022`,
where students' own consoles show `< 2.2e-16`. Set display options in `_setup.R`, or set and
restore inside the chunk. Same hazard for `par()`, `theme_set()`, and `options(digits=)`.

### A raw `<style>` block at the top level becomes its own slide

A `` ```{=html} `` style block between sections rendered as slide 15 of 89. Put deck-scoped CSS
*inside* a section slide (right under a `#` header) — it applies document-wide and shows nothing.

### Fixing a content bug can push a slide over 720px

Restoring the dropped table rows made two previously-"passing" slides overflow. Re-run the full
sweep after every fix; never assume a repair is local.

Overflow remedies in order of preference: `{.smaller}`; trim a figure's `fig-height`; then a
scoped CSS class for spacing (this deck defines `.tight` for slides pairing a display equation
with a long table). Cutting content is a `slide-style` decision, not a rendering fix — raise it
rather than deciding it here.

### Reserved chunk-label prefixes

Labels must be `viz-`/`table-`. A `fig-` or `tbl-` label triggers Quarto crossref numbering and
stamps a stray "Figure 1" caption onto the slide. Cheap to grep before rendering.

## Low-prior checks

Audited clean across a 1,000-line deck and not worth prose unless something points at them:
unbalanced `\left`/`\right`, unescaped `%`/`&`/`_`/`#` inside math, unbalanced `:::` divs,
non-ASCII characters (the U+2212 minus that `slide-style` warns about in ggplot labels), and
horizontal overflow of `pre`/`table`/`img`. `audit.js` covers the last one for free.

## When the source looks right but the render doesn't

Work outward from the source, not inward from the DOM. Read Pandoc's HTML directly
(`grep` the `.html` for the surrounding sentence) to see what Pandoc actually emitted — that
single step distinguishes "Pandoc mis-parsed my markdown" from "MathJax hasn't run" from "CSS is
clipping it," and those three look identical on screen. Inspect the DOM only for layout questions:
MathJax rewrites structure, so post-typeset DOM tells you nothing about a source-level cause.

## See also

- `slide-style` — what belongs on a slide, and the ≤720px rule this skill measures.
- `slides/_setup.R` — `math_usd()`, `cell_usd()`, and the dataset loaders.
