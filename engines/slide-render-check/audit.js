// Paste into the browser console (javascript_tool) with a rendered deck loaded.
// Returns JSON: every automated check in one pass.
//
// Prerequisites, both of which have caused false results here:
//   1. Load the deck in a BRAND-NEW tab (tabs_create + navigate). The preview pane
//      serves stale file:// snapshots to reused tabs.
//   2. Resize to 1280x800 before running.
//
// A clean result is: over/scipen/hover/labels empty, untypedMath 0, mjxErrors 0,
// and every table's row count equal to what the source says it should be.

(async () => {
  // --- Freshness: prove which file is loaded before trusting anything below.
  const loaded = location.pathname.split('/').pop();

  // --- Wait for MathJax and webfonts. Measuring before these settle reports
  //     wrong heights AND makes correct math look broken.
  if (typeof MathJax !== 'undefined' && MathJax.typesetPromise) {
    await MathJax.typesetPromise();
  }
  if (document.fonts && document.fonts.ready) await document.fonts.ready;
  await new Promise(r => setTimeout(r, 300));
  Reveal.layout();

  const slides = Reveal.getSlides();
  const over = [];      // vertical clipping (the deck is 720px tall)
  const scipen = [];    // options(scipen=) leak signature
  const hover = [];     // horizontal overflow
  const tables = [];    // row counts - compare against the source
  const macros = [];    // LaTeX that escaped its math span into body text

  const title = s => ((s.querySelector('h1,h2') || {}).textContent || '(untitled)').slice(0, 45);

  for (let i = 0; i < slides.length; i++) {
    const s = slides[i];
    const ix = Reveal.getIndices(s);
    Reveal.slide(ix.h, ix.v, 99);  // 99 => show all fragments
    Reveal.layout();               // required, or r-stretch figures measure as 0
    const t = title(s);

    if (s.scrollHeight > 720) over.push({ i, t, h: s.scrollHeight });

    s.querySelectorAll('pre').forEach(p => {
      if (/0\.0{6,}\d/.test(p.textContent || '')) scipen.push({ i, t });
    });

    s.querySelectorAll('pre, table, img').forEach(el => {
      if (el.scrollWidth > el.clientWidth + 4) hover.push({ i, t, tag: el.tagName });
    });

    const tb = s.querySelector('table');
    if (tb) tables.push({ i, t, rows: tb.querySelectorAll('tbody tr').length });

    // LaTeX macros surviving as literal text outside a rendered math container
    // are the fingerprint of a math span that pandoc broke.
    const clone = s.cloneNode(true);
    clone.querySelectorAll('mjx-container, script, pre, code').forEach(n => n.remove());
    const stray = (clone.textContent || '').match(
      /\\(times|approx|pm|hat|beta|frac|left|right|text|mid|sim|epsilon|sigma|bar|widehat|underbrace)/g
    );
    if (stray) macros.push({ i, t, macros: [...new Set(stray)] });
  }

  // Reserved chunk-label prefixes stamp stray "Figure 1" captions onto slides.
  const labels = [...document.querySelectorAll('figcaption, caption')]
    .map(c => c.textContent.trim())
    .filter(x => /^(Figure|Table)\s+\d/.test(x));

  const mathSpans = [...document.querySelectorAll('span.math')];
  const untypedMath = mathSpans.filter(sp => !sp.querySelector('mjx-container')).length;

  return JSON.stringify({
    loaded,
    totalSlides: slides.length,
    over, scipen, hover, macros, labels, tables,
    mathSpans: mathSpans.length,
    untypedMath,                                   // >0 means MathJax didn't finish: re-run
    mjxErrors: document.querySelectorAll('mjx-merror').length
  }, null, 1);
})()
