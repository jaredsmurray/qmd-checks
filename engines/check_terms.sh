#!/usr/bin/env bash
#
# Terminology guard for the book's chapter prose.
#
# The canonical forms live in style_terms.tsv; this is the only thing that reads
# them. Three modes:
#
#   --all           scan every chapter .qmd, report drift, exit 1 if any
#   --fix           rewrite to the canonical form in place (review with git diff)
#   --hook          PostToolUse: read the tool JSON on stdin, check that one file
#   --all <files>   restrict the scan to specific files
#
# Why a script and not a sed one-liner: every rule here has a near-miss context
# that must not change. `zipcode` is also the column name, geom_boxplot is a
# function, and prob_05_multivariate-distributions.qmd carries a correct
# "small-business loan" on the same line as a \text{small business} table label.
# So the checker skips fenced chunk bodies (except `#|` option lines, which are
# prose), inline `code` spans, $math$, and HTML comments -- and only then looks
# for drift.

set -uo pipefail

# Project root. Installed toolkit copies live at <root>/tools/checks/, the
# legacy in-repo layout at <root>/tools/; QMD_CHECKS_ROOT overrides both.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${QMD_CHECKS_ROOT:-}" ]; then
  REPO="$(cd "$QMD_CHECKS_ROOT" && pwd)"
elif [ "$(basename "$SCRIPT_DIR")" = checks ]; then
  REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# Scan-set declaration. Defaults reproduce the original book behavior; a
# project overrides them in tools/checks.conf (KEY=VALUE, shell syntax).
#   TERMS_RULES       rules TSV, relative to the project root
#   TERMS_GLOBS       space-separated globs (relative to root) for --all/--fix
#   TERMS_EXCLUDE_RE  basename regex to skip (generated files etc.)
TERMS_RULES="style_terms.tsv"
TERMS_GLOBS="*.qmd"
TERMS_EXCLUDE_RE='^(sap_sampling_app|sap_bootstrap_app)\.qmd$'
[ -f "$REPO/tools/checks.conf" ] && . "$REPO/tools/checks.conf"

RULES="$REPO/$TERMS_RULES"
EXCLUDE_RE="$TERMS_EXCLUDE_RE"

# Expand the declared globs into the default scan set (sorted, deduped).
# The subshell runs the word-split of TERMS_GLOBS under `set -f`: without it
# the shell would glob-expand the patterns against the CALLER'S cwd before the
# loop ever sees them.
scan_set() {
  (
    set -f
    for g in $TERMS_GLOBS; do
      set +f
      for f in "$REPO"/$g; do
        [ -f "$f" ] || continue
        echo "$(basename "$f")" | grep -Eq "$EXCLUDE_RE" && continue
        printf '%s\n' "$f"
      done
      set -f
    done
  ) | sort -u
}

usage() {
  echo "usage: tools/check_terms.sh --all [files...] | --fix [files...] | --hook" >&2
  exit 64
}

[ $# -ge 1 ] || usage
mode_flag="$1"; shift

case "$mode_flag" in
  --all)  mode=check ;;
  --fix)  mode=fix ;;
  --hook) mode=hook ;;
  *)      usage ;;
esac

[ -f "$RULES" ] || { echo "ERROR: missing rules file: $RULES" >&2; exit 70; }

# --- Which files -------------------------------------------------------------

files=()

if [ "$mode" = hook ]; then
  # PostToolUse hands us the tool call as JSON on stdin. Anything that isn't a
  # chapter .qmd is none of our business, so stay silent and exit clean.
  payload="$(cat)"
  if command -v jq >/dev/null 2>&1; then
    fp="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    fp="$(printf '%s' "$payload" | python3 -c \
      'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' \
      2>/dev/null)"
  else
    exit 0   # no JSON parser available; never block an edit over it
  fi
  [ -n "${fp:-}" ] || exit 0
  case "$fp" in *.qmd) ;; *) exit 0 ;; esac
  [ -f "$fp" ] || exit 0
  # In scope only if the declared scan set contains it. Decks, problem sets
  # and supplements are separate projects with their own conventions (or their
  # own checks.conf).
  abs="$(cd "$(dirname "$fp")" && pwd)/$(basename "$fp")"
  scan_set | grep -Fxq "$abs" || exit 0
  files=("$abs")
  mode=check
elif [ $# -gt 0 ]; then
  files=("$@")
else
  while IFS= read -r f; do
    files+=("$f")
  done < <(scan_set)
fi

[ ${#files[@]} -gt 0 ] || exit 0

# --- The work ----------------------------------------------------------------

# A hook's findings have to reach the model on stderr, and exit 2 is what marks
# them as something to act on rather than log noise.
[ "$mode_flag" = --hook ] && exec 1>&2

perl - "$mode" "$RULES" "${files[@]}" <<'PERL'
use strict;
use warnings;

my $mode  = shift @ARGV;
my $rules = shift @ARGV;

# Load the rules table.
my @RULES;
open my $rfh, '<', $rules or die "cannot read $rules: $!\n";
while (my $line = <$rfh>) {
    chomp $line;
    next if $line =~ /^\s*#/ || $line !~ /\S/;
    my ($pat, $repl, $skip, $note) = split /\t/, $line, 4;
    next unless defined $pat && length $pat && defined $repl;
    $skip = '' unless defined $skip;
    $note = '' unless defined $note;
    push @RULES, {
        pat  => qr/$pat/,
        repl => $repl,
        skip => (length $skip ? qr/$skip/ : undef),
        note => $note,
    };
}
close $rfh;
die "no rules loaded from $rules\n" unless @RULES;

# Spans the rules must never see. Order matters: code spans first, so a stray
# `$` inside backticks can't open a phantom math span. Escaped \$ (the book's
# literal dollar sign) is not a math delimiter.
my $PROTECTED = qr{
    ( `[^`]*`
    | \$\$.*?\$\$
    | (?<!\\)\$ (?: [^\$\\] | \\. )* (?<!\\) \$
    | <!--.*?-->
    )
}x;

# Apply one rule to the unprotected segments of a string. Returns the new
# string and the list of [before, after] pairs that changed.
sub apply_rule {
    my ($text, $rule) = @_;
    my @hits;
    # split on a capturing pattern interleaves: plain, protected, plain, ...
    my @parts = split /$PROTECTED/, $text, -1;
    for my $i (0 .. $#parts) {
        next if $i % 2;                      # odd index == protected span
        next unless defined $parts[$i];
        $parts[$i] =~ s{$rule->{pat}}{
            my @g = ($1, $2, $3, $4, $5, $6, $7, $8, $9);
            my $before = $&;
            my $after  = $rule->{repl};
            $after =~ s/\$([1-9])/defined $g[$1-1] ? $g[$1-1] : ''/ge;
            push @hits, [$before, $after];
            $after;
        }ge;
    }
    return (join('', @parts), \@hits);
}

my $total = 0;
my $files_touched = 0;

for my $file (@ARGV) {
    open my $fh, '<', $file or die "cannot read $file: $!\n";
    my @lines = <$fh>;
    close $fh;

    my ($in_fence, $in_comment, $changed) = (0, 0, 0);
    my @report;

    for my $n (0 .. $#lines) {
        my $line = $lines[$n];
        my $eol  = ($line =~ s/(\r?\n)\z//) ? $1 : '';

        # A multi-line HTML comment swallows everything until it closes. This is
        # what protects the outline note in twovar_04_multivariate.qmd, which
        # names the zipcode column inside a TODO block.
        if ($in_comment) {
            if ($line =~ /-->/) { $in_comment = 0; }
            $lines[$n] = $line . $eol;
            next;
        }
        if ($line =~ /<!--/ && $line !~ /-->/) {
            $in_comment = 1;
            $lines[$n] = $line . $eol;
            next;
        }

        # Fence toggling.
        if ($line =~ /^\s*```/) {
            $in_fence = !$in_fence;
            $lines[$n] = $line . $eol;
            next;
        }
        # Inside a chunk, only the caption fields are reader-facing prose that
        # can drift. Every other `#|` option is a machine value -- a `label:` of
        # `fig-boxplot-price` must stay one token, or the fix inserts a space and
        # breaks the label and every @ref to it -- and the code itself is code.
        if ($in_fence && $line !~ /^\s*#\|\s*(?:fig-cap|tbl-cap|fig-subcap|tbl-subcap|fig-scap|fig-alt)\s*:/) {
            $lines[$n] = $line . $eol;
            next;
        }

        my $orig = $line;
        for my $rule (@RULES) {
            next if $rule->{skip} && $orig =~ $rule->{skip};
            my ($new, $hits) = apply_rule($line, $rule);
            next unless @$hits;
            $line = $new;
            for my $h (@$hits) {
                push @report, sprintf("  %s:%d: %s -> %s  (%s)",
                    $file, $n + 1, $h->[0], $h->[1], $rule->{note});
                $total++;
            }
        }

        if ($line ne $orig) {
            $changed = 1;
            $lines[$n] = $line . $eol;
        } else {
            $lines[$n] = $orig . $eol;
        }
    }

    next unless @report;
    $files_touched++;
    print join("\n", @report), "\n";

    if ($mode eq 'fix' && $changed) {
        open my $out, '>', $file or die "cannot write $file: $!\n";
        print $out @lines;
        close $out;
    }
}

if ($total) {
    my $noun = $total == 1 ? 'site' : 'sites';
    my $fnoun = $files_touched == 1 ? 'file' : 'files';
    if ($mode eq 'fix') {
        print "\nFixed $total $noun in $files_touched $fnoun. Review with: git diff --word-diff\n";
        exit 0;
    }
    print "\n$total $noun drifted from style_terms.tsv across $files_touched $fnoun.\n";
    print "Fix with: ./tools/check_terms.sh --fix\n";
    exit 1;
}
exit 0;
PERL
status=$?

# --- Numeric conventions ------------------------------------------------------
# Hard rules that apply EVERYWHERE in a chapter -- including code chunks and
# math spans, which the prose rules above deliberately never see. Ruled by
# Jared in the ch. 21 adjudication (2026-07-28): the book's 95% normal
# multiplier is 2 (the 68/95/99.7 convention), never 1.96 -- in prose, in
# displayed math, and in the code that computes displayed intervals, so the
# reader-visible arithmetic closes (see tools/check_rounded_arithmetic.R).
num_status=0
for f in "${files[@]}"; do
  hits=$(grep -nE '(^|[^0-9])1\.96($|[^0-9])' "$f" || true)
  [ -z "$hits" ] && continue
  if [ "$mode" = fix ]; then
    perl -i -pe 's/(?<![0-9])1\.96(?![0-9])/2/g' "$f"
    printf '%s\n' "$hits" | sed "s|^|  $f:|"
    echo "  ^ replaced 1.96 -> 2 (house 95% multiplier). Review with: git diff"
  else
    printf '%s\n' "$hits" | sed "s|^|  $f:|; s|\$|   [1.96 -> 2: house 95% multiplier]|"
    num_status=1
  fi
done
[ "$status" -eq 0 ] && status=$num_status

# 1 means "drift found". A hook has to say 2 for the finding to come back as
# something to fix; everywhere else 1 is the useful non-zero.
if [ "$mode_flag" = --hook ] && [ "$status" -eq 1 ]; then
  exit 2
fi
exit "$status"
