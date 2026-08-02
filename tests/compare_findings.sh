#!/usr/bin/env bash
#
# Phase gate harness: do the toolkit-installed engines report exactly what the
# project's own in-repo copies report?
#
#   tests/compare_findings.sh [--book <dir>] [--keep] <project-dir>
#
# For each engine it runs the project's original (tools/<engine>) and the
# installed copy (tools/checks/<engine>) with equivalent arguments, mirroring
# how ship.sh invokes each check today, and diffs stdout+stderr+exit status.
#
#   check_terms.sh                --all              (ship.sh: terms stage)
#   check_number_consistency.R    --all              (ship.sh: numbers stage)
#   check_rounded_arithmetic.R    <changed .html>    (ship.sh: arith stage --
#                                 needs a rendered book; see --book below)
#   slide-render-check            not executable -- a skill plus a browser
#                                 harness driven by a model. Compared by file
#                                 diff only; there is no findings output to
#                                 reproduce without a live browser session.
#
# --book <dir>   directory of rendered HTML for the arithmetic check. Defaults
#                to <project-dir>/_book. If neither exists the arithmetic
#                comparison is SKIPPED (loudly), not failed: that engine cannot
#                run without a render.
# --keep         keep the temp output dir for inspection.
#
# Exit: 0 all comparable pairs agree, 1 a pair disagreed, 2 usage/setup error.
#
# Invocation note: the engines resolve config and their --all scan set from
# their own parent directory. An installed copy is therefore driven through a
# temporary symlink at tools/.qmdchecks-cmp-<engine>, which puts its parent
# back at tools/ so it sees the same project root as the original. The symlinks
# are removed on exit. install.sh makes the same arrangement permanent via its
# tools/<engine> entry points.

set -uo pipefail

book_dir=""
keep=false
project=""

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --book)  [ $# -ge 2 ] || usage; book_dir="$2"; shift 2 ;;
    --book=*) book_dir="${1#--book=}"; shift ;;
    --keep)  keep=true; shift ;;
    -h|--help) usage ;;
    -*)      echo "unknown option: $1" >&2; usage ;;
    *)       [ -z "$project" ] || usage; project="$1"; shift ;;
  esac
done

[ -n "$project" ] || usage
[ -d "$project" ] || { echo "ERROR: no such directory: $project" >&2; exit 2; }
project="$(cd "$project" && pwd)"
[ -d "$project/tools/checks" ] ||
  { echo "ERROR: $project/tools/checks not found -- run install.sh first" >&2; exit 2; }

out="$(mktemp -d "${TMPDIR:-/tmp}/qmd-checks-cmp.XXXXXX")"
cleanup() {
  rm -f "$project"/tools/.qmdchecks-cmp-*
  if [ "$keep" = true ]; then echo "outputs kept in $out"; else rm -rf "$out"; fi
}
trap cleanup EXIT

fails=0; passes=0; skips=0

# Run a command, capturing stdout+stderr and exit status, with project paths and
# the shim's own name normalized so only real finding differences survive.
run() {  # run <label> <outfile> <command...>
  local label="$1" file="$2"; shift 2
  ( cd "$project" && "$@" ) > "$file.raw" 2>&1
  local rc=$?
  sed -e "s|$project/||g" -e "s|$project||g" \
      -e "s|\.qmdchecks-cmp-||g" -e "s|tools/checks/|tools/|g" \
      "$file.raw" > "$file"
  echo "exit=$rc" >> "$file"
  return 0
}

compare() {  # compare <name> <original-out> <installed-out>
  local name="$1" a="$2" b="$3"
  if diff -u "$a" "$b" > "$out/$name.diff"; then
    echo "PASS  $name -- identical findings and exit status"
    passes=$((passes + 1))
  else
    echo "FAIL  $name -- outputs differ:"
    sed 's/^/      /' "$out/$name.diff"
    fails=$((fails + 1))
  fi
}

SHIM=""
shim_for() {  # shim_for <engine>; sets $SHIM to the invocation path
  local e="$1"
  SHIM="$project/tools/.qmdchecks-cmp-$e"
  ln -sf "checks/$e" "$SHIM" || { echo "ERROR: cannot create shim $SHIM" >&2; exit 2; }
}

# --- 1. check_terms.sh --all --------------------------------------------------

if [ -f "$project/tools/check_terms.sh" ] && [ ! -L "$project/tools/check_terms.sh" ]; then
  shim_for check_terms.sh
  run orig "$out/terms_orig" "$project/tools/check_terms.sh" --all
  run inst "$out/terms_inst" "$SHIM" --all
  compare check_terms "$out/terms_orig" "$out/terms_inst"
else
  echo "SKIP  check_terms -- no in-repo original at tools/check_terms.sh"
  skips=$((skips + 1))
fi

# --- 2. check_number_consistency.R --all --------------------------------------

if [ -f "$project/tools/check_number_consistency.R" ] &&
   [ ! -L "$project/tools/check_number_consistency.R" ]; then
  shim_for check_number_consistency.R
  run orig "$out/numbers_orig" Rscript "$project/tools/check_number_consistency.R" --all
  run inst "$out/numbers_inst" Rscript "$SHIM" --all
  compare check_number_consistency "$out/numbers_orig" "$out/numbers_inst"
else
  echo "SKIP  check_number_consistency -- no in-repo original"
  skips=$((skips + 1))
fi

# --- 3. check_rounded_arithmetic.R <html files> -------------------------------
# ship.sh passes an explicit list of the HTML files a deploy changed, so the
# engine's own --all/_book discovery never runs there. Mirror that: an explicit
# file list, which also means no config or root resolution is involved.

if [ -z "$book_dir" ] && [ -d "$project/_book" ]; then book_dir="$project/_book"; fi

if [ ! -f "$project/tools/check_rounded_arithmetic.R" ] ||
   [ -L "$project/tools/check_rounded_arithmetic.R" ]; then
  echo "SKIP  check_rounded_arithmetic -- no in-repo original"
  skips=$((skips + 1))
elif [ -z "$book_dir" ] || [ ! -d "$book_dir" ]; then
  echo "SKIP  check_rounded_arithmetic -- needs rendered HTML; pass --book <dir>"
  echo "      (this engine reads a render, so it cannot be compared from source alone)"
  skips=$((skips + 1))
else
  html=()   # bash 3.2 on macOS has no mapfile
  while IFS= read -r h; do html+=("$h"); done < <(find "$book_dir" -name '*.html' | sort)
  if [ ${#html[@]} -eq 0 ]; then
    echo "SKIP  check_rounded_arithmetic -- no .html under $book_dir"
    skips=$((skips + 1))
  else
    echo "      check_rounded_arithmetic: ${#html[@]} HTML file(s) from $book_dir"
    run orig "$out/arith_orig" Rscript "$project/tools/check_rounded_arithmetic.R" "${html[@]}"
    run inst "$out/arith_inst" Rscript "$project/tools/checks/check_rounded_arithmetic.R" "${html[@]}"
    compare check_rounded_arithmetic "$out/arith_orig" "$out/arith_inst"
  fi
fi

# --- 4. slide-render-check ----------------------------------------------------
# No CLI, no findings stream: SKILL.md is instructions for a model and audit.js
# runs inside a browser session. The only mechanical check available is that the
# vendored copy still matches the project's.

orig_skill=""
for cand in "$project/.claude/skills/slide-render-check" \
            "$project/.agents/skills/slide-render-check"; do
  [ -d "$cand" ] && { orig_skill="$cand"; break; }
done
if [ -z "$orig_skill" ]; then
  echo "SKIP  slide-render-check -- no in-repo copy to compare against"
  skips=$((skips + 1))
elif [ ! -d "$project/tools/checks/slide-render-check" ]; then
  echo "SKIP  slide-render-check -- not installed"
  skips=$((skips + 1))
elif diff -r "$orig_skill" "$project/tools/checks/slide-render-check" > "$out/skill.diff" 2>&1; then
  echo "PASS  slide-render-check -- vendored copy matches ${orig_skill#$project/}"
  passes=$((passes + 1))
else
  echo "FAIL  slide-render-check -- vendored copy differs from ${orig_skill#$project/}:"
  sed 's/^/      /' "$out/skill.diff"
  fails=$((fails + 1))
fi

echo ""
echo "compare_findings: $passes passed, $fails failed, $skips skipped"
[ "$fails" -eq 0 ] || exit 1
exit 0
