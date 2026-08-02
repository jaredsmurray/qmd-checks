# qmd-checks

Reusable check and audit engines for Quarto projects, plus a vendoring
installer. Extracted verbatim from the `intro_notes_revision` monorepo
(§6 of its modular refactor plan); nothing here is book-specific except the
templates, which exist to be overwritten.

## The engines

| Engine | Reads | What it catches |
| --- | --- | --- |
| `engines/check_rounded_arithmetic.R` | rendered `.html` | Explicit arithmetic on a page — `a op b = r`, `a ± b = [lo, hi]` — re-evaluated using the numbers the reader can actually see. Catches the round-then-compute class, where an inline expression computes on unrounded values while the page shows the operands rounded independently. Blind to numbers inside figure images. |
| `engines/check_number_consistency.R` | `.qmd` source | Every displayed number that passes through a `scales` formatter, inventoried and compared. Rule A: one expression formatted at two accuracies in the same file. Rule B: a figure value the reader can reconstruct from other values in the same figure, so their arithmetic has to close at the shown precision. Sees inside figures, which the HTML checker cannot; never evaluates, so Rule B is a risk flag, not a proven mismatch. |
| `engines/check_terms.sh` | `.qmd` source | House terminology drift, driven by a TSV of Perl rules. The engine is a protected-span rewriter: fenced chunk bodies (except `#|` option lines), inline code spans, `$math$`, and HTML comments are invisible to the rules, which is what keeps a term that is also a column name or a function name out of scope. `--all` reports, `--fix` rewrites in place, `--hook` checks the single file a `PostToolUse` payload names. |
| `engines/slide-render-check/` | a rendered revealjs deck, in a browser | Not a CLI. A skill (`SKILL.md`) plus a browser harness (`audit.js`) that a model drives: equations that silently lost their middle, tables missing rows, slides clipped past 720px, chunk options leaking into output. All failures Quarto reports as a clean render. |

The first three exit 0 clean, 1 with findings, 2 on usage error. All findings
are advisory — a clean run is not a clean chapter.

## Engines here, config in the project

The split is the whole point of the package:

- **Engines** (this repo): the regex machinery, the parse and re-evaluation
  logic, the protected-span rules. Generic across projects.
- **Config** (each project, never here): `style_terms.tsv` — the house
  terminology; `tools/number_consistency_ignore.tsv` — precision differences
  the project has adjudicated as deliberate, plus the note explaining each
  ruling; and any terminology ledger or review record that sits beside them.

`templates/` holds *seeds* for the config files: the format documentation
and a handful of illustrative rows, marked as templates in their own header
comments. They are a starting point, not a shared default — replace the example
rules with your own.

### Declaring the scan set: `tools/checks.conf`

Each project declares *which files its checks scan* in an optional
`tools/checks.conf` (plain shell `KEY=VALUE`; seeded from `templates/`).
`TERMS_GLOBS` / `TERMS_RULES` / `TERMS_EXCLUDE_RE` drive `check_terms.sh`;
`NUMCONS_GLOBS` / `NUMCONS_EXCLUDE_RE` / `NUMCONS_IGNORE` drive
`check_number_consistency.R`; `ARITH_HTML_DIR` points
`check_rounded_arithmetic.R --all` at the rendered output. Globs are relative
to the project root. With no config file the engines fall back to built-in
defaults that reproduce the original book repo's behavior (root `*.qmd`,
`slides/*.qmd` for number consistency, `_book/` for arithmetic).

Engines locate their project root from where they're installed —
`tools/checks/` (toolkit layout) or `tools/` (legacy in-repo layout) — and
`QMD_CHECKS_ROOT` overrides the discovery, which is also how you point an
engine at a project it isn't installed in. Explicit file arguments always
bypass the declared scan set; hook mode treats "in the scan set" as "in
scope".

## Distribution: vendored installer

No submodule, no package install. `install.sh` copies files:

```
./install.sh [--ref <tag>] [options] <project-dir>
```

- copies the engines to `<project-dir>/tools/checks/`,
- writes `<project-dir>/tools/checks/VERSION` (toolkit `git describe` + SHA +
  install time), so a project can say what it is running,
- creates `tools/<engine>` symlinks into `checks/` — see below — unless a real
  file is already there,
- seeds a config template **only when the project has no such file**; existing
  config is never overwritten, on the first install or any later one,
- `--hook-snippet` prints the optional `.claude/settings.json` `PostToolUse`
  snippet (`--hook-snippet=<file>` writes it; it refuses to overwrite). Merge it
  into an existing settings file by hand — the installer does not edit JSON.

Re-running updates the engines in place and leaves config alone. `--ref <tag>`
installs the engines as of a toolkit tag via `git archive`, so a project can pin
a version and re-pin later.

### Why the `tools/<engine>` symlinks

The engines are vendored **verbatim**, and each one resolves its config and its
`--all` scan set relative to its own parent directory (script dir + `/..`). A
copy invoked as `tools/checks/check_terms.sh` would therefore look for
`style_terms.tsv` under `tools/`, not the project root. The symlinks
`tools/check_terms.sh -> checks/check_terms.sh` restore the original invocation
path, so the engines see the project root exactly as the monorepo originals do
and existing `ship.sh` / hook command lines keep working unchanged. Pass
`--no-entrypoints` to skip them; they become unnecessary once the engines grow
the `--files` / config-path parameterization.

## Verifying a migration

`tests/compare_findings.sh [--book <dir>] <project-dir>` runs each installed
engine and the project's own in-repo counterpart with equivalent arguments —
mirroring how `ship.sh` invokes each check today — and diffs findings and exit
status:

- `check_terms.sh --all` and `check_number_consistency.R --all`, both run from
  the project root, the installed copy driven through a temporary
  `tools/.qmdchecks-cmp-*` symlink so both resolve the same root;
- `check_rounded_arithmetic.R` over an explicit list of `.html` files, the way
  `ship.sh` passes the pages a deploy changed. **This engine cannot run without
  a render**: pass `--book <dir>` (default `<project-dir>/_book`), or the
  comparison is skipped loudly rather than failed;
- `slide-render-check` has no findings output at all — it is a model-driven
  browser procedure — so it is compared by file diff only.

## Known limitation

Vendored copies go stale silently. Nothing phones home, nothing warns when a
project's `tools/checks/` lags the toolkit; `VERSION` is the only record, and
only if someone reads it. This is accepted: the checks are advisory, so
staleness weakens checking rather than breaking a build, and nag machinery for
an advisory check is worse than the drift.
