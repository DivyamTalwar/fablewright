#!/bin/sh

set -eu

VERSION=1.0.0

usage() {
  cat <<'EOF'
Usage: bump-version.sh <new-version> [--dry-run]

Rewrite the version in every file that declares it, then verify they agree.
<new-version> must be MAJOR.MINOR.PATCH, optionally with a pre-release or build suffix.

  --dry-run   Show what would change; write nothing.
  --version   Print this script's own version.
  --help      Show this help text.

After bumping, add a CHANGELOG entry yourself - that part is not mechanical.
EOF
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  exit "${2:-1}"
}

new_version=''
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --version) printf 'bump-version.sh %s\n' "$VERSION"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    -*) fail "unknown argument: $1 (run with --help for usage)." 64 ;;
    *)
      [ -z "$new_version" ] || fail "give exactly one version." 64
      new_version=$1
      shift
      ;;
  esac
done

[ -n "$new_version" ] || { usage >&2; exit 64; }
printf '%s\n' "$new_version" |
  LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' ||
  fail "version must be MAJOR.MINOR.PATCH, optionally with a -pre or +build suffix (got '$new_version')." 64

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd) || fail "could not resolve the repository root."
cd "$repo_root"

manifests='.claude-plugin/plugin.json .codex-plugin/plugin.json'
scripts='scripts/install-agents.sh scripts/cast-call.sh scripts/ask-wright.sh
scripts/inspect-agent-runtime.sh scripts/bump-version.sh'
verifier='scripts/verify.sh'

current=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .claude-plugin/plugin.json | head -1)
[ -n "$current" ] || fail "could not read the current version from .claude-plugin/plugin.json."

if [ "$current" = "$new_version" ]; then
  printf 'Already at %s; nothing to do.\n' "$new_version"
  exit 0
fi

printf 'Bumping %s -> %s\n' "$current" "$new_version"

for f in $manifests $scripts $verifier; do
  [ -f "$f" ] || fail "missing file: $f"
done

if [ "$dry_run" -eq 1 ]; then
  for f in $manifests; do printf '  would set "version": "%s" in %s\n' "$new_version" "$f"; done
  for f in $scripts;   do printf '  would set VERSION=%s in %s\n' "$new_version" "$f"; done
  printf '  would set EXPECTED_VERSION=%s in %s\n' "$new_version" "$verifier"
  exit 0
fi

tmp_base=${TMPDIR:-/tmp}
case "$tmp_base" in /*) ;; *) tmp_base=/tmp ;; esac

rewrite() {
  file=$1
  expression=$2
  staged=$(mktemp "$tmp_base/fablewright-bump.XXXXXX") || fail "could not stage $file."
  if ! sed "$expression" "$file" > "$staged"; then
    rm -f "$staged"
    fail "could not rewrite $file."
  fi
  if ! cat "$staged" > "$file"; then
    rm -f "$staged"
    fail "could not write $file."
  fi
  rm -f "$staged"
  printf '  updated %s\n' "$file"
}

for f in $manifests; do
  rewrite "$f" "s/\"version\"[[:space:]]*:[[:space:]]*\"$current\"/\"version\": \"$new_version\"/"
done
for f in $scripts; do
  rewrite "$f" "s/^VERSION=$current\$/VERSION=$new_version/"
done
rewrite "$verifier" "s/^EXPECTED_VERSION=$current\$/EXPECTED_VERSION=$new_version/"

printf '\nVerifying every declaration agrees:\n'
mismatch=0
for f in $manifests; do
  grep -Fq "\"version\": \"$new_version\"" "$f" || { printf '  MISMATCH: %s\n' "$f"; mismatch=1; }
done
for f in $scripts; do
  grep -Fq "VERSION=$new_version" "$f" || { printf '  MISMATCH: %s\n' "$f"; mismatch=1; }
done
grep -Fq "EXPECTED_VERSION=$new_version" "$verifier" || { printf '  MISMATCH: %s\n' "$verifier"; mismatch=1; }
[ "$mismatch" -eq 0 ] || fail "the bump left files disagreeing; fix them before releasing."

printf '  all declarations agree at %s\n' "$new_version"
printf '\nNext: add a CHANGELOG.md entry, then run sh scripts/verify.sh\n'
