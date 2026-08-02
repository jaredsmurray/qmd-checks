#!/usr/bin/env bash
#
# Vendored installer for the qmd-checks engines.
#
#   install.sh [--ref <tag>] [options] <project-dir>
#
# Copies the check engines into <project-dir>/tools/checks/, records what was
# installed in <project-dir>/tools/checks/VERSION, and seeds config files from
# templates/ ONLY where the project has none. Re-running updates the engines in
# place and never touches config.
#
# Options:
#   --ref <tag>        install the engines as of a toolkit tag/SHA/branch
#                      (default: the toolkit working tree)
#   --no-entrypoints   skip the tools/<engine> -> checks/<engine> symlinks
#   --no-config        do not seed config templates at all
#   --hook-snippet     print the .claude/settings.json PostToolUse snippet
#   --hook-snippet=<f> write that snippet to <f> (refuses to overwrite)
#   --dry-run          print what would happen, change nothing
#   -h, --help         this text
#
# No submodules, no package installs: the engines are plain files, and a
# vendored copy is expected to go stale until someone re-runs this. See README.

set -uo pipefail

TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ref=""
entrypoints=true
seed_config=true
hook_mode=""      # "" | print | <path>
dry_run=false
project=""

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)            [ $# -ge 2 ] || usage; ref="$2"; shift 2 ;;
    --ref=*)          ref="${1#--ref=}"; shift ;;
    --no-entrypoints) entrypoints=false; shift ;;
    --no-config)      seed_config=false; shift ;;
    --hook-snippet)   hook_mode=print; shift ;;
    --hook-snippet=*) hook_mode="${1#--hook-snippet=}"; shift ;;
    --dry-run)        dry_run=true; shift ;;
    -h|--help)        usage ;;
    -*)               echo "unknown option: $1" >&2; usage ;;
    *)                [ -z "$project" ] || { echo "one project dir, please" >&2; usage; }
                      project="$1"; shift ;;
  esac
done

[ -n "$project" ] || usage
[ -d "$project" ] || { echo "ERROR: no such directory: $project" >&2; exit 66; }
project="$(cd "$project" && pwd)"

say() { printf '%s\n' "$*"; }
do_or_say() { if [ "$dry_run" = true ]; then say "would: $*"; else "$@"; fi; }

# --- Which engine bytes ------------------------------------------------------
# Default is the toolkit working tree. With --ref we export that ref to a temp
# dir instead, so a project can pin a tag and re-pin later.

src="$TOOLKIT"
tmpdir=""
if [ -n "$ref" ]; then
  git -C "$TOOLKIT" rev-parse --verify "$ref^{commit}" >/dev/null 2>&1 ||
    { echo "ERROR: not a commit in the toolkit repo: $ref" >&2; exit 65; }
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/qmd-checks.XXXXXX")"
  git -C "$TOOLKIT" archive "$ref" | tar -x -C "$tmpdir" ||
    { echo "ERROR: could not export $ref" >&2; exit 70; }
  src="$tmpdir"
fi
cleanup() { [ -n "$tmpdir" ] && rm -rf "$tmpdir"; }
trap cleanup EXIT

describe="$(git -C "$TOOLKIT" describe --tags --always ${ref:+"$ref"} 2>/dev/null || echo unknown)"
sha="$(git -C "$TOOLKIT" rev-parse ${ref:+"$ref"} 2>/dev/null || echo unknown)"
[ -n "$ref" ] || {
  dirty="$(git -C "$TOOLKIT" status --porcelain 2>/dev/null)"
  [ -z "$dirty" ] || describe="$describe-dirty"
}

ENGINES=(check_rounded_arithmetic.R check_number_consistency.R check_terms.sh)
SKILL=slide-render-check

for e in "${ENGINES[@]}"; do
  [ -f "$src/engines/$e" ] || { echo "ERROR: missing engine: engines/$e" >&2; exit 70; }
done

# --- Install -----------------------------------------------------------------

dest="$project/tools/checks"
do_or_say mkdir -p "$dest"

for e in "${ENGINES[@]}"; do
  do_or_say cp "$src/engines/$e" "$dest/$e"
  do_or_say chmod +x "$dest/$e"
  say "engine: tools/checks/$e"
done

if [ -d "$src/engines/$SKILL" ]; then
  if [ "$dry_run" = true ]; then
    say "would: cp -R $src/engines/$SKILL $dest/"
  else
    rm -rf "$dest/$SKILL"
    cp -R "$src/engines/$SKILL" "$dest/$SKILL"
  fi
  say "engine: tools/checks/$SKILL/ (skill + audit.js)"
fi

if [ "$dry_run" = true ]; then
  say "would: write tools/checks/VERSION ($describe / $sha)"
else
  {
    echo "toolkit: qmd-checks"
    echo "ref: ${ref:-<working tree>}"
    echo "describe: $describe"
    echo "sha: $sha"
    echo "installed: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "source: qmd-checks"   # repo name only; a local path here would leak into public repos
    echo ""
    echo "# Vendored copy. It does not update itself; re-run the toolkit's"
    echo "# install.sh to refresh. Config files are project-owned and are never"
    echo "# overwritten by an install."
  } > "$dest/VERSION"
  say "wrote:  tools/checks/VERSION"
fi

# --- Entry points ------------------------------------------------------------
# The engines self-locate the project root from tools/checks/ (and honor
# QMD_CHECKS_ROOT), so these symlinks are pure invocation-path compatibility:
# scripts and hooks written against the legacy tools/check_*.sh paths keep
# working unchanged. New projects can pass --no-entrypoints and call
# tools/checks/* directly.

if [ "$entrypoints" = true ]; then
  for e in "${ENGINES[@]}"; do
    link="$project/tools/$e"
    if [ -L "$link" ]; then
      do_or_say ln -sf "checks/$e" "$link"
      say "entry:  tools/$e -> checks/$e"
    elif [ -e "$link" ]; then
      say "kept:   tools/$e (a real file already lives there; not replaced)"
    else
      do_or_say ln -s "checks/$e" "$link"
      say "entry:  tools/$e -> checks/$e"
    fi
  done
fi

# --- Config seeding ----------------------------------------------------------
# Engines here, config in the project. Seed only what is missing.

seed() {  # seed <template> <project-relative destination>
  local tpl="$src/templates/$1" out="$project/$2"
  [ -f "$tpl" ] || { say "skip:   no template $1"; return; }
  if [ -e "$out" ]; then
    say "kept:   $2 (project config, untouched)"
  else
    do_or_say mkdir -p "$(dirname "$out")"
    do_or_say cp "$tpl" "$out"
    say "seeded: $2 (from template -- edit it)"
  fi
}

if [ "$seed_config" = true ]; then
  seed style_terms.tsv                style_terms.tsv
  seed number_consistency_ignore.tsv  tools/number_consistency_ignore.tsv
  seed checks.conf                    tools/checks.conf
fi

# --- Optional PostToolUse hook snippet ---------------------------------------

hook_snippet() {
  cat <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/tools/check_terms.sh --hook"
          },
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/tools/check_number_consistency.R --hook"
          }
        ]
      }
    ]
  }
}
JSON
}

case "$hook_mode" in
  "") ;;
  print)
    say ""
    say "# Optional .claude/settings.json PostToolUse hook (merge by hand):"
    hook_snippet
    ;;
  *)
    if [ "$dry_run" = true ]; then
      say "would: write hook snippet to $hook_mode"
    elif [ -e "$hook_mode" ]; then
      echo "ERROR: refusing to overwrite $hook_mode; merge the snippet by hand:" >&2
      hook_snippet >&2
      exit 73
    else
      mkdir -p "$(dirname "$hook_mode")"
      hook_snippet > "$hook_mode"
      say "wrote:  $hook_mode (PostToolUse hook snippet)"
    fi
    ;;
esac

say ""
say "done: $describe installed into $project/tools/checks"
[ "$dry_run" = true ] && say "(dry run -- nothing changed)"
exit 0
