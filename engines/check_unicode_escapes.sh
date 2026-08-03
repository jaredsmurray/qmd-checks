#!/usr/bin/env bash
#
# Detect R's C-locale unicode mangling in rendered output.
#
# R running without a UTF-8 locale prints non-ASCII characters as literal
# "<U+XXXX>" text -- em dashes become <U+2014>, the minus sign <U+2212> --
# and the render exits clean, so nothing upstream notices. Prevention lives
# in ~/.Renviron and the projects' shared setup files; this check is the
# detector for anything that slips through in TEXT output. Text inside PNG
# figures cannot be scanned -- a mangled caption from the same R session is
# usually the visible symptom.
#
# Usage:
#   tools/checks/check_unicode_escapes.sh [path ...]
#     paths may be .html files, .pdf files (needs pdftotext), or directories
#     (scanned recursively for both). With no arguments, scans the directory
#     named by ARITH_HTML_DIR in tools/checks.conf (default _book).
#
# Exit: 0 clean, 1 findings, 2 usage/error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${QMD_CHECKS_ROOT:-}" ]; then
  REPO="$(cd "$QMD_CHECKS_ROOT" && pwd)"
elif [ "$(basename "$SCRIPT_DIR")" = checks ]; then
  REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

ARITH_HTML_DIR="_book"
[ -f "$REPO/tools/checks.conf" ] && . "$REPO/tools/checks.conf"

# The signature, in raw text and in HTML entity encoding.
PAT='(<|&lt;)U\+[0-9A-Fa-f]{4,6}(>|&gt;)'

targets=()
if [ $# -gt 0 ]; then
  targets=("$@")
else
  targets=("$REPO/$ARITH_HTML_DIR")
fi

files=()
for t in "${targets[@]}"; do
  if [ -d "$t" ]; then
    while IFS= read -r f; do files+=("$f"); done \
      < <(find "$t" \( -name '*.html' -o -name '*.pdf' \) -type f | sort)
  elif [ -f "$t" ]; then
    files+=("$t")
  else
    echo "ERROR: no such file or directory: $t" >&2; exit 2
  fi
done

[ ${#files[@]} -gt 0 ] || { echo "nothing to scan"; exit 0; }

found=0
for f in "${files[@]}"; do
  case "$f" in
    *.pdf)
      command -v pdftotext >/dev/null 2>&1 || { echo "skip (no pdftotext): $f"; continue; }
      hits=$(pdftotext "$f" - 2>/dev/null | grep -cE "$PAT" || true)
      ;;
    *)
      hits=$(grep -cE "$PAT" "$f" 2>/dev/null || true)
      ;;
  esac
  if [ "${hits:-0}" -gt 0 ]; then
    echo "MANGLED UNICODE: $f ($hits site(s) print literal <U+XXXX>)"
    found=$((found + hits))
  fi
done

if [ "$found" -gt 0 ]; then
  echo ""
  echo "$found <U+XXXX> escape(s) found: an R session rendered without a UTF-8"
  echo "locale. Fix the environment (see ~/.Renviron and the project setup"
  echo "files), re-render, and re-check."
  exit 1
fi
echo "ok: no C-locale unicode escapes in ${#files[@]} scanned file(s)"
exit 0
