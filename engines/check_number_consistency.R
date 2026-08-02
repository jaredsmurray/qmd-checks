#!/usr/bin/env Rscript
#
# Number-consistency checker for chapter and slide source.
#
# The sibling checker, check_rounded_arithmetic.R, reads rendered HTML and
# re-evaluates explicit "a op b = r" statements. It cannot see numbers that live
# inside a figure -- those are pixels by the time the page exists -- and it
# cannot see a quantity that is simply printed at two different precisions on
# two surfaces, because neither printing is wrong on its own.
#
# Those are the two bugs that keep recurring in chapter reviews:
#
#   ch. 13, still open: Pr(R < -3%) prints at three decimals in a section
#     bullet and at two in the Figure 13.4 panel title.
#   ch. 13, Fig 13.4:   0.77 - 0.12 != 0.64 at two decimals. The three-decimal
#     fix failed too, because one addend rounds up while the other rounds down.
#
# Both are visible in the SOURCE, before anything renders, because this book
# formats essentially every displayed number through scales. So this reads the
# .qmd, inventories every formatter call -- prose inline spans, table mutates,
# and figure label code alike -- and compares them:
#
#   Rule A, precision drift: one expression, formatted at two accuracies in the
#     same file. Reported with each site's line and surface.
#
#   Rule B, reconstructible figure values: a figure displays a value that the
#     reader can rebuild from the other values in the same figure -- so their
#     arithmetic has to close at the precision they are all shown at, and
#     independently rounded operands routinely don't. Both routes through
#     Figure 13.4 land here.
#
# Rule B reports a structural risk, not a proven mismatch: this reads source and
# never evaluates, so it cannot know whether a given subtraction closes. Some
# will. That is the price of seeing inside a figure at all.
#
# Matching is on the expression's parsed form, not on its value, so `0.5`
# appearing all over the book never collides with itself: only
# `pnorm(-0.03, mu_r, sd_r)` matches `pnorm( -0.03, mu_r, sd_r )`.
#
# Both findings are advisory. A per-surface precision difference is often the
# author's deliberate choice; adjudicated pairs go in
# tools/number_consistency_ignore.tsv and stay quiet after that.
#
# Known blind spots, by design: axis ticks built with scales' label_*() closures
# (the formatting happens inside ggplot2, not at a call site we can read);
# numbers hardcoded as literals rather than computed (slides and the coding
# supplements are mostly literals); and anything formatted with sprintf or
# formatC rather than scales. A clean run is not a clean chapter.
#
# Usage:
#   tools/check_number_consistency.R <file.qmd> [...]
#   tools/check_number_consistency.R --all        # chapters + slides
#   tools/check_number_consistency.R --hook       # PostToolUse, stdin JSON
#
# Exit: 0 clean, 1 findings, 2 usage/error. In --hook mode a finding exits 2,
# which is what makes it actionable, and output goes to stderr.

# --- Arguments ---------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)

script_path <- sub("^--file=", "",
                   grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
script_dir <- dirname(normalizePath(script_path))

# Project root. Installed toolkit copies live at <root>/tools/checks/, the
# legacy in-repo layout at <root>/tools/; QMD_CHECKS_ROOT overrides both.
REPO <- Sys.getenv("QMD_CHECKS_ROOT", "")
REPO <- if (nzchar(REPO)) {
  normalizePath(REPO)
} else if (basename(script_dir) == "checks") {
  normalizePath(file.path(script_dir, "..", ".."))
} else {
  normalizePath(file.path(script_dir, ".."))
}

# Scan-set declaration: optional tools/checks.conf (KEY=VALUE, shell syntax,
# shared with the other engines). Defaults reproduce the original book
# behavior: chapters at the root plus the slides/ subproject.
read_conf <- function(path) {
  if (!file.exists(path)) return(list())
  ln <- readLines(path, warn = FALSE)
  ln <- ln[grepl("^[A-Z_]+=", ln)]
  kv <- regmatches(ln, regexec("^([A-Z_]+)=(.*)$", ln))
  out <- list()
  for (m in kv) out[[m[2]]] <- gsub("^[\"']|[\"']$", "", m[3])
  out
}
conf <- read_conf(file.path(REPO, "tools", "checks.conf"))
conf_or <- function(key, default) {
  if (!is.null(conf[[key]]) && nzchar(conf[[key]])) conf[[key]] else default
}
NUMCONS_GLOBS <- strsplit(conf_or("NUMCONS_GLOBS", "*.qmd slides/*.qmd"),
                          "[[:space:]]+")[[1]]

usage <- function() {
  cat("usage: tools/check_number_consistency.R --all | --hook | <file.qmd> ...\n",
      file = stderr())
  quit(status = 2)
}

if (length(args) == 0) usage()

hook_mode <- identical(args[1], "--hook")

# Generated wrappers, not authored prose: sap_*.qmd come from webapps/*/app.R.
EXCLUDE_RE <- conf_or("NUMCONS_EXCLUDE_RE",
                      "^(sap_sampling_app|sap_bootstrap_app)\\.qmd$")

if (hook_mode) {
  # PostToolUse hands us the tool call as JSON on stdin. Anything that is not a
  # .qmd is none of our business, so stay silent and exit clean -- and never
  # block an edit because a JSON parser was missing.
  payload <- paste(readLines(file("stdin"), warn = FALSE), collapse = "\n")
  fp <- ""
  if (nzchar(Sys.which("jq"))) {
    fp <- suppressWarnings(system2("jq", c("-r", "'.tool_input.file_path // empty'"),
                                   input = payload, stdout = TRUE, stderr = NULL))
  } else if (nzchar(Sys.which("python3"))) {
    fp <- suppressWarnings(system2("python3", c("-c",
      shQuote("import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))")),
      input = payload, stdout = TRUE, stderr = NULL))
  } else {
    quit(status = 0)
  }
  fp <- fp[nzchar(fp)][1]
  if (is.na(fp) || !nzchar(fp) || !grepl("\\.qmd$", fp) || !file.exists(fp)) quit(status = 0)
  if (grepl(EXCLUDE_RE, basename(fp))) quit(status = 0)
  files <- fp
} else if (identical(args[1], "--all")) {
  files <- unlist(lapply(NUMCONS_GLOBS, function(g) Sys.glob(file.path(REPO, g))))
  files <- unique(files[file.exists(files)])
  files <- files[!grepl(EXCLUDE_RE, basename(files))]
  files <- files[!grepl("^_", basename(files))]
} else {
  files <- args
  missing <- files[!file.exists(files)]
  if (length(missing)) {
    cat("ERROR: no such file:", paste(missing, collapse = ", "), "\n", file = stderr())
    quit(status = 2)
  }
}

out <- if (hook_mode) stderr() else stdout()

# --- Suppressions ------------------------------------------------------------

IGNORE_PATH <- file.path(REPO, conf_or("NUMCONS_IGNORE",
                                       "tools/number_consistency_ignore.tsv"))
ignores <- if (file.exists(IGNORE_PATH)) {
  z <- try(read.delim(IGNORE_PATH, comment.char = "#", stringsAsFactors = FALSE),
           silent = TRUE)
  if (inherits(z, "try-error") || !all(c("file", "expr") %in% names(z))) {
    data.frame(file = character(), expr = character())
  } else z
} else data.frame(file = character(), expr = character())

suppressed <- function(f, e) {
  any(ignores$file == f & ignores$expr == e)
}

# --- Source scanning ---------------------------------------------------------

FORMATTERS <- c("number", "dollar", "comma", "percent", "label_percent",
                "format_signed", "math_usd", "cell_usd")

# An unannotated call still has a precision, and it is usually 1 in the
# formatter's own units -- so an unannotated math_usd() is not a different
# precision from an explicit dollar(accuracy = 1). math_usd/cell_usd are defined
# identically in slides/_setup.R:15,19 and copy-pasted into regression_01/03/04.
#
# dollar() is deliberately absent: its default shows cents below $100,000 and
# whole dollars above (scales' largest_with_cents), so its precision depends on
# the value and cannot be read off the source. Sites we can't resolve are
# excluded from comparison rather than guessed at.
DEFAULT_ACCURACY <- list(number = "1", comma = "1", percent = "1",
                         label_percent = "1", math_usd = "1", cell_usd = "1")

# Blank a character range in place, preserving every offset (and every newline,
# so line numbers survive).
blank_range <- function(chars, from, to) {
  if (to < from) return(chars)
  idx <- from:to
  keep <- chars[idx] == "\n"
  chars[idx][!keep] <- " "
  chars
}

# Walk forward from the "(" at `open` to its matching ")", ignoring brackets
# inside string literals.
match_paren <- function(chars, open) {
  depth <- 0L
  i <- open
  n <- length(chars)
  quote_ch <- ""
  while (i <= n) {
    ch <- chars[i]
    if (nzchar(quote_ch)) {
      if (ch == "\\") i <- i + 1L
      else if (ch == quote_ch) quote_ch <- ""
    } else if (ch == "\"" || ch == "'") {
      quote_ch <- ch
    } else if (ch == "(") {
      depth <- depth + 1L
    } else if (ch == ")") {
      depth <- depth - 1L
      if (depth == 0L) return(i)
    }
    i <- i + 1L
  }
  NA_integer_
}

# Everything we need to know about one .qmd: where the chunks are, what each one
# is for, and a copy of the text with comments blanked out.
scan_source <- function(path) {
  lines <- readLines(path, warn = FALSE)
  nl <- length(lines)
  if (nl == 0) return(NULL)

  # Chunk regions. A fence opens with ```{...} and closes with a bare ```.
  fence_open  <- grepl("^\\s*```+\\{", lines)
  fence_close <- grepl("^\\s*```+\\s*$", lines)
  chunks <- list()
  i <- 1L
  while (i <= nl) {
    if (fence_open[i]) {
      j <- i + 1L
      while (j <= nl && !fence_close[j]) j <- j + 1L
      engine <- tolower(sub("^\\s*```+\\{([a-zA-Z0-9]+).*$", "\\1", lines[i]))
      body <- if (j - 1L >= i + 1L) lines[(i + 1L):(j - 1L)] else character()
      lab <- grep("^\\s*#\\|\\s*label\\s*:", body, value = TRUE)
      label <- if (length(lab)) trimws(sub("^\\s*#\\|\\s*label\\s*:\\s*", "", lab[1])) else ""
      chunks[[length(chunks) + 1L]] <- list(
        start = i, end = min(j, nl), engine = engine, label = label,
        body = paste(body, collapse = "\n"))
      i <- j + 1L
    } else i <- i + 1L
  }

  # Offsets: character position of the first character of each line.
  text <- paste(lines, collapse = "\n")
  chars <- strsplit(text, "", fixed = TRUE)[[1]]
  line_start <- cumsum(c(1L, nchar(lines) + 1L))[seq_len(nl)]
  line_of <- function(pos) findInterval(pos, line_start)

  in_chunk <- logical(nl)
  for (ck in chunks) in_chunk[ck$start:ck$end] <- TRUE

  masked <- chars

  # Blank the fence lines themselves, and any non-R chunk wholesale.
  for (ck in chunks) {
    drop <- if (ck$engine %in% c("r")) c(ck$start, ck$end) else ck$start:ck$end
    for (ln in drop) {
      masked <- blank_range(masked, line_start[ln],
                            line_start[ln] + nchar(lines[ln]) - 1L)
    }
  }

  # Blank R comments inside chunks (a `#` outside a string, to end of line).
  for (ln in which(in_chunk)) {
    s <- lines[ln]
    if (!nzchar(s)) next
    cs <- strsplit(s, "", fixed = TRUE)[[1]]
    quote_ch <- ""; cut <- NA_integer_; k <- 1L
    while (k <= length(cs)) {
      ch <- cs[k]
      if (nzchar(quote_ch)) {
        if (ch == "\\") k <- k + 1L else if (ch == quote_ch) quote_ch <- ""
      } else if (ch == "\"" || ch == "'") quote_ch <- ch
      else if (ch == "#") { cut <- k; break }
      k <- k + 1L
    }
    if (!is.na(cut)) {
      masked <- blank_range(masked, line_start[ln] + cut - 1L,
                            line_start[ln] + nchar(s) - 1L)
    }
  }

  # Blank HTML comments in prose. regression_05_interactions.qmd keeps a long
  # commented-out block; nothing in it is reader-visible.
  # (?s) so a comment can span lines -- regression_06_nonlinear.qmd parks whole
  # draft paragraphs, inline r spans and all, inside multi-line comments.
  cm <- gregexpr("(?s)<!--.*?-->", text, perl = TRUE)[[1]]
  if (cm[1] != -1) {
    for (k in seq_along(cm)) {
      masked <- blank_range(masked, cm[k], cm[k] + attr(cm, "match.length")[k] - 1L)
    }
  }

  # Inline `r ...` spans, on the masked text so commented-out ones are gone.
  masked_text <- paste(masked, collapse = "")
  im <- gregexpr("`r[ \n][^`]*`", masked_text, perl = TRUE)[[1]]
  inline <- if (im[1] == -1) integer(0) else {
    cbind(im, im + attr(im, "match.length")[seq_along(im)] - 1L)
  }

  list(path = path, lines = lines, chunks = chunks, masked = masked,
       masked_text = masked_text, line_start = line_start, line_of = line_of,
       inline = inline, in_chunk = in_chunk)
}

# Where does a call at character position `pos` show up for the reader?
classify_surface <- function(src, pos, chunk) {
  if (nrow(as.matrix(src$inline)) && length(src$inline)) {
    if (any(src$inline[, 1] <= pos & pos <= src$inline[, 2])) return("inline")
  }
  if (is.null(chunk)) return("prose")

  # Lexically inside a label-building call?
  body_from <- src$line_start[chunk$start]
  body_to <- src$line_start[chunk$end] + nchar(src$lines[chunk$end]) - 1L
  seg <- paste(src$masked[body_from:body_to], collapse = "")
  fm <- gregexpr("\\b(geom_text|geom_label|annotate|labs|ggtitle|element_text)\\s*\\(",
                 seg, perl = TRUE)[[1]]
  if (fm[1] != -1) {
    for (k in seq_along(fm)) {
      open <- body_from + fm[k] + attr(fm, "match.length")[k] - 2L
      close <- match_paren(src$masked, open)
      if (!is.na(close) && open <= pos && pos <= close) return("figure")
    }
  }
  if (grepl("^fig-", chunk$label)) return("figure")
  if (grepl("\\b(kable|kbl|reg_table|coef_table)\\s*\\(", chunk$body, perl = TRUE))
    return("table")
  "chunk"
}

# One row per formatter call: what expression is displayed, at what accuracy.
display_sites <- function(src) {
  pat <- paste0("\\b(", paste(FORMATTERS, collapse = "|"), ")\\s*\\(")
  m <- gregexpr(pat, src$masked_text, perl = TRUE)[[1]]
  if (m[1] == -1) return(NULL)
  lens <- attr(m, "match.length")

  rows <- list()
  for (k in seq_along(m)) {
    start <- m[k]
    # A qualified call (scales::number) formats the same way; keep it.
    open <- start + lens[k] - 1L
    close <- match_paren(src$masked, open)
    if (is.na(close)) next
    call_text <- paste(src$masked[start:close], collapse = "")
    e <- try(parse(text = call_text)[[1]], silent = TRUE)
    if (inherits(e, "try-error") || !is.call(e)) next
    a <- as.list(e)[-1]
    if (!length(a)) next
    nm <- names(a); if (is.null(nm)) nm <- rep("", length(a))
    val <- a[nm == ""][1]
    if (!length(val) || is.null(val[[1]])) next
    fn_name <- sub("\\s*\\($", "", substr(src$masked_text, start, open))
    acc <- if ("accuracy" %in% nm) {
      paste(deparse(a[["accuracy"]]), collapse = "")
    } else if (sub("^.*::", "", fn_name) %in% names(DEFAULT_ACCURACY)) {
      DEFAULT_ACCURACY[[sub("^.*::", "", fn_name)]]
    } else NA_character_
    # percent() multiplies by 100 before rounding, so accuracy = 1 there is the
    # same resolution as accuracy = 0.01 in number(). Compare what the reader
    # actually loses, not the argument as typed.
    scale <- if (grepl("percent", fn_name)) 0.01 else 1
    accn <- suppressWarnings(as.numeric(acc))
    res <- if (is.na(accn)) NA_character_ else format(accn * scale, scientific = FALSE)
    expr <- gsub("[[:space:]]+", " ",
                 paste(deparse(val[[1]], width.cutoff = 500L), collapse = " "))
    ln <- src$line_of(start)
    chunk <- NULL
    for (ck in src$chunks) if (ck$start <= ln && ln <= ck$end) { chunk <- ck; break }
    rows[[length(rows) + 1L]] <- data.frame(
      line = ln,
      fn = fn_name,
      expr = expr,
      accuracy = acc,
      resolution = res,
      surface = classify_surface(src, start, chunk),
      chunk = if (is.null(chunk)) "" else chunk$label,
      stringsAsFactors = FALSE)
  }
  if (!length(rows)) return(NULL)
  do.call(rbind, rows)
}

# An expression carries a fingerprint only if it names something. A bare `x`,
# `prob`, or a literal is a helper-function parameter, and the same name in two
# helpers is not the same quantity.
informative <- function(expr) {
  if (!grepl("[A-Za-z]", expr)) return(FALSE)
  e <- try(parse(text = expr)[[1]], silent = TRUE)
  if (inherits(e, "try-error")) return(FALSE)
  !is.symbol(e) || nchar(expr) > 12
}

# --- Rule B support: reconstructible figure values ---------------------------

# Split a top-level +/- expression into its terms. `a + 1 - b` -> a, 1, b.
flatten_terms <- function(e) {
  if (is.call(e) && length(e) == 3L && as.character(e[[1]]) %in% c("+", "-")) {
    return(c(flatten_terms(e[[2]]), flatten_terms(e[[3]])))
  }
  if (is.call(e) && length(e) == 2L && as.character(e[[1]]) == "-") {
    return(flatten_terms(e[[2]]))
  }
  list(e)
}

norm_expr <- function(e) {
  gsub("[[:space:]]+", " ", paste(deparse(e, width.cutoff = 500L), collapse = " "))
}

# --- Rule A: precision drift -------------------------------------------------

n_findings <- 0L

for (f in files) {
  src <- try(scan_source(f), silent = TRUE)
  if (inherits(src, "try-error") || is.null(src)) next
  sites <- display_sites(src)
  if (is.null(sites)) next

  rel <- sub(paste0("^", REPO, "/"), "", normalizePath(f))
  file_out <- character()

  for (e in unique(sites$expr)) {
    if (!informative(e)) next
    g <- sites[sites$expr == e & !is.na(sites$resolution), , drop = FALSE]
    if (nrow(g) < 2 || length(unique(g$resolution)) < 2) next
    if (suppressed(rel, e)) next
    g <- g[order(g$line), , drop = FALSE]
    file_out <- c(file_out,
      sprintf("  PRECISION DRIFT: %s", e),
      sprintf("    %s:%d: %s(accuracy = %s)  [%s]",
              rel, g$line, g$fn, g$accuracy, g$surface))
    n_findings <- n_findings + 1L
  }

  # Rule B. Inside one figure, a value the reader can rebuild from the other
  # values on display has to close at the precision they are all shown at --
  # and independently rounded operands routinely don't. This is Figure 13.4's
  # bug, and the reason its three-decimal fix failed too.
  figs <- sites[sites$surface == "figure" & nzchar(sites$chunk) &
                  !is.na(sites$resolution), , drop = FALSE]
  for (ck in unique(figs$chunk)) {
    g <- figs[figs$chunk == ck, , drop = FALSE]
    shown <- unique(g$expr)
    for (i in seq_len(nrow(g))) {
      e <- try(parse(text = g$expr[i])[[1]], silent = TRUE)
      if (inherits(e, "try-error")) next
      terms <- flatten_terms(e)
      if (length(terms) < 2) next
      atoms <- vapply(terms, norm_expr, character(1))
      atoms <- atoms[!grepl("^-?[0-9.]+$", atoms)]        # literals are free
      if (!length(atoms)) next
      if (!all(atoms %in% shown)) next                     # not reconstructible
      if (suppressed(rel, g$expr[i])) next
      src_rows <- g[g$expr %in% atoms, , drop = FALSE]
      if (!all(src_rows$resolution == g$resolution[i])) next
      file_out <- c(file_out,
        sprintf("  RECONSTRUCTIBLE FIGURE VALUE: %s", g$expr[i]),
        sprintf("    %s:%d: shown at accuracy %s, in chunk %s",
                rel, g$line[i], g$accuracy[i], ck),
        "    the same figure already displays every operand:",
        sprintf("      %s:%d: %s", rel, src_rows$line, src_rows$expr),
        "    a reader can redo this subtraction; check that it closes at that precision")
      n_findings <- n_findings + 1L
    }
  }

  if (length(file_out)) cat(paste(file_out, collapse = "\n"), "\n", sep = "", file = out)
}

# A hook that talks on every clean edit is a hook people learn to ignore.
if (!hook_mode || n_findings > 0) {
  cat(sprintf("%d displayed-precision finding(s) across %d file(s)\n",
              n_findings, length(files)), file = out)
}
if (n_findings > 0 && !hook_mode) {
  cat("Adjudicated-as-fine pairs go in tools/number_consistency_ignore.tsv\n", file = out)
}

quit(status = if (n_findings == 0L) 0L else if (hook_mode) 2L else 1L)
