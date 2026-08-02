#!/usr/bin/env Rscript
#
# Rounded-arithmetic checker for rendered HTML.
#
# The bug class (todo/ch20_review_followups.md item 2): an inline expression
# computes with unrounded values while the page displays the operands
# independently rounded, so the arithmetic a reader can actually do with the
# numbers in front of them contradicts the printed result. Three exemplars in
# four consecutive chapter reviews (ch. 20's 0.015-vs-0.014, ch. 13's panel
# titles, ch. 22's off-by-a-dollar ZIP display).
#
# So this reads what the reader reads: it extracts the visible text of rendered
# HTML (prose, list items, table cells, captions, and the TeX source of math
# spans), finds explicit arithmetic statements
#
#     a op b [op c ...] = r          op in + - x / (and TeX \times, \cdot)
#     a +- b = [lo, hi]              plus-minus with an interval result
#
# and re-evaluates each one USING THE DISPLAYED VALUES. A statement passes if
# the printed result equals the recomputed one at the result's own displayed
# precision:
#
#   - decimals shown        -> half a unit in the last printed decimal place
#   - trailing zeros, no    -> the result may be rounded to those zeros
#     decimals                 ($224,000 from 571,000 - 346,724 is fine)
#   - otherwise             -> exact ("=$361,428" must be the round-then-
#                              subtract answer, not the subtract-then-round one)
#
# "~" / \approx statements get one extra unit of slack. Known blind spots, by
# design: numbers inside figure PNGs (no text to read), and a result whose
# trailing zeros are load-bearing (60 + 39 = 100 slips through the
# rounded-to-hundreds allowance). Statements mixing letters into the math
# (model equations like 10,103 + 280.37x) are skipped, not checked.
#
# Usage:
#   tools/check_rounded_arithmetic.R <file.html> [...]
#   tools/check_rounded_arithmetic.R --all          # every .html under _book/
#   add --verbose to list the statements that passed, per file
#
# Exit: 0 clean, 1 findings, 2 usage/error.

suppressMessages(library(xml2))

args <- commandArgs(trailingOnly = TRUE)
verbose <- "--verbose" %in% args
args <- setdiff(args, "--verbose")

if (length(args) == 0) {
  cat("usage: tools/check_rounded_arithmetic.R [--verbose] --all | <file.html> ...\n",
      file = stderr())
  quit(status = 2)
}

if (identical(args, "--all")) {
  # Project root: installed toolkit copies live at <root>/tools/checks/, the
  # legacy in-repo layout at <root>/tools/; QMD_CHECKS_ROOT overrides both.
  script_dir <- dirname(normalizePath(sub("--file=", "", grep("^--file=",
                  commandArgs(FALSE), value = TRUE)[1])))
  root <- Sys.getenv("QMD_CHECKS_ROOT", "")
  root <- if (nzchar(root)) {
    normalizePath(root)
  } else if (basename(script_dir) == "checks") {
    normalizePath(file.path(script_dir, "..", ".."))
  } else {
    normalizePath(file.path(script_dir, ".."))
  }
  # Rendered-output dir from tools/checks.conf (ARITH_HTML_DIR), default _book.
  html_dir <- "_book"
  conf_path <- file.path(root, "tools", "checks.conf")
  if (file.exists(conf_path)) {
    ln <- grep("^ARITH_HTML_DIR=", readLines(conf_path, warn = FALSE), value = TRUE)
    if (length(ln)) {
      v <- gsub("^[\"']|[\"']$", "", sub("^ARITH_HTML_DIR=", "", ln[1]))
      if (nzchar(v)) html_dir <- v
    }
  }
  files <- list.files(file.path(root, html_dir), pattern = "\\.html$",
                      recursive = TRUE, full.names = TRUE)
} else {
  files <- args
}
missing <- files[!file.exists(files)]
if (length(missing)) {
  cat("ERROR: no such file:", paste(missing, collapse = ", "), "\n", file = stderr())
  quit(status = 2)
}

# --- Text extraction ---------------------------------------------------------

# Blocks a statement can live inside. Math spans sit inside <p>, so their TeX
# source arrives with the paragraph text.
BLOCK_XPATH <- "//p | //li | //td | //th | //caption | //figcaption | //h1 | //h2 | //h3 | //h4"

block_texts <- function(path) {
  doc <- read_html(path)
  xml_remove(xml_find_all(doc, "//script | //style"))
  txt <- enc2utf8(xml_text(xml_find_all(doc, BLOCK_XPATH)))
  txt <- iconv(txt, "UTF-8", "UTF-8", sub = " ")
  unique(txt[nzchar(trimws(txt))])
}

# TeX and unicode -> one plain-text arithmetic dialect.
normalize <- function(x) {
  x <- gsub("\\\\[()\\[\\]]", " ", x, perl = TRUE)          # \( \) \[ \]
  x <- gsub("\\\\(left|right|,|;|!|:| )", " ", x, perl = TRUE)
  x <- gsub("\\\\\\$", "$", x)                              # \$  -> $
  x <- gsub("\\{,\\}", ",", x, fixed = FALSE)               # {,} -> ,
  x <- gsub("\\\\(times|cdot)\\b", " x ", x, perl = TRUE)
  x <- gsub("\\\\pm\\b", " +- ", x, perl = TRUE)
  x <- gsub("\\\\approx\\b", " ~ ", x, perl = TRUE)
  x <- gsub("\\\\%", "%", x, fixed = TRUE)
  x <- gsub(sprintf("[%s]", intToUtf8(c(0x2212, 0x2013))), "-", x, perl = TRUE)  # minus, en dash
  x <- gsub(intToUtf8(0xB1), " +- ", x, perl = TRUE)
  x <- gsub(sprintf("[%s]", intToUtf8(c(0xD7, 0x22C5))), " x ", x, perl = TRUE)  # multiplication
  x <- gsub(intToUtf8(0x2248), " ~ ", x, perl = TRUE)
  gsub("[[:space:]]+", " ", x)
}

# --- Statement grammar -------------------------------------------------------

NUM <- "-?\\$?[0-9]+(?:,[0-9]{3})*(?:\\.[0-9]+)?%?"
OP  <- "(?:\\+-|[-+/]|x)"
EXPR <- paste0(NUM, "(?: ?", OP, " ?", NUM, "){1,6}")
RHS  <- paste0("(?:\\[ ?", NUM, " ?, ?", NUM, " ?\\]|", NUM, ")")
# Trailing guard: no digit may follow (a truncated number), but a sentence-final
# period is fine.
STMT <- paste0("(?<![A-Za-z0-9_.])(", EXPR, ") ?([=~]) ?(", RHS, ")(?![A-Za-z0-9]|\\.[0-9])")

parse_num <- function(tok) as.numeric(gsub("[$,%]", "", tok))

# How exactly must the printed result match? Returns the comparison unit.
result_unit <- function(tok) {
  tok <- gsub("[$,%-]", "", tok)
  if (grepl("\\.", tok)) {
    10^-nchar(sub("^[0-9]*\\.", "", tok))
  } else {
    tz <- nchar(tok) - nchar(sub("0+$", "", tok))
    if (tz > 0) 10^tz else 1
  }
}

# Evaluate "a op b op c ..." with x,/ before +,-; a top-level +- yields c(lo, hi).
eval_expr <- function(expr) {
  toks <- regmatches(expr, gregexpr(paste0(NUM, "|", OP), expr, perl = TRUE))[[1]]
  vals <- list(); ops <- character()
  expect_num <- TRUE
  for (t in toks) {
    if (expect_num) {
      if (!grepl("[0-9]", t)) return(NULL)
      vals <- c(vals, parse_num(t)); expect_num <- FALSE
    } else {
      ops <- c(ops, t); expect_num <- TRUE
    }
  }
  if (expect_num || length(vals) != length(ops) + 1) return(NULL)
  # pass 1: x and /
  i <- 1
  while (i <= length(ops)) {
    if (ops[i] %in% c("x", "/")) {
      v <- if (ops[i] == "x") vals[[i]] * vals[[i + 1]] else vals[[i]] / vals[[i + 1]]
      vals[[i]] <- v; vals[[i + 1]] <- NULL; ops <- ops[-i]
    } else i <- i + 1
  }
  # pass 2: left to right; +- must be the last operator standing
  acc <- vals[[1]]
  for (i in seq_along(ops)) {
    if (ops[i] == "+-") {
      if (i != length(ops)) return(NULL)
      return(c(acc - vals[[i + 1]], acc + vals[[i + 1]]))
    }
    acc <- if (ops[i] == "+") acc + vals[[i + 1]] else acc - vals[[i + 1]]
  }
  acc
}

check_result <- function(value, shown_tok, approx) {
  shown <- parse_num(shown_tok)
  unit <- result_unit(shown_tok)
  slack <- if (approx) 1.5 * unit else 0.5 * unit
  ok_round <- abs(round(value / unit) * unit - shown) < 1e-9 * max(1, abs(shown))
  ok_near  <- abs(value - shown) <= slack + 1e-9 * max(1, abs(shown))
  ok_round || ok_near
}

# --- Run ---------------------------------------------------------------------

n_flagged <- 0L
n_checked <- 0L

for (f in files) {
  blocks <- normalize(block_texts(f))
  seen <- character()
  file_flags <- character(); file_passes <- character()

  for (b in blocks) {
    m <- gregexpr(STMT, b, perl = TRUE)
    stmts <- regmatches(b, m)[[1]]
    for (s in stmts) {
      if (s %in% seen) next
      seen <- c(seen, s)
      parts <- regmatches(s, regexec(STMT, s, perl = TRUE))[[1]]
      lhs <- parts[2]; rel <- parts[3]; rhs <- parts[4]
      value <- eval_expr(lhs)
      if (is.null(value)) next
      approx <- rel == "~"
      if (grepl("^\\[", rhs)) {
        if (length(value) != 2) next
        ends <- regmatches(rhs, gregexpr(NUM, rhs, perl = TRUE))[[1]]
        if (length(ends) != 2) next
        ok <- check_result(value[1], ends[1], approx) &&
              check_result(value[2], ends[2], approx)
        computed <- sprintf("[%s, %s]", format(value[1], big.mark = ","),
                            format(value[2], big.mark = ","))
      } else {
        if (length(value) != 1) next
        ok <- check_result(value, rhs, approx)
        computed <- format(value, big.mark = ",")
      }
      n_checked <- n_checked + 1L
      if (ok) {
        file_passes <- c(file_passes, s)
      } else {
        file_flags <- c(file_flags,
          sprintf("  MISMATCH: %s\n            displayed operands give: %s", s, computed))
      }
    }
  }

  if (length(file_flags)) {
    n_flagged <- n_flagged + length(file_flags)
    cat(f, "\n", paste(file_flags, collapse = "\n"), "\n", sep = "")
  }
  if (verbose && length(file_passes)) {
    cat(f, " [ok]\n", paste0("  ", file_passes, collapse = "\n"), "\n", sep = "")
  }
}

cat(sprintf("checked %d statement(s) across %d file(s): %d mismatch(es)\n",
            n_checked, length(files), n_flagged))
quit(status = if (n_flagged > 0) 1L else 0L)
