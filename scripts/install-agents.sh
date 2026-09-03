#!/bin/sh

set -eu

VERSION=1.0.0

usage() {
  cat <<'EOF'
Usage: install-agents.sh [--host HOST] [--target-dir PATH]
                         [--check] [--check-role ROLE ...] [--dry-run] [--list]

Install FABLEWRIGHT's pinned lane profiles for a host.

  --host HOST        codex (default) or claude-code.
  --target-dir PATH  Explicit destination directory. Defaults to
                     "$CODEX_HOME/agents" or "$HOME/.codex/agents" for codex, and
                     "$CLAUDE_CONFIG_DIR/agents" or "$HOME/.claude/agents" for
                     claude-code.
  --check            Verify every profile matches exactly. Mutates nothing.
  --check-role ROLE  Verify only ROLE. Repeatable; implies --check. Accepts a full
                     role id or an unambiguous prefix. An ambiguous prefix fails.
  --dry-run          Print exactly what would change. Mutates nothing.
  --list             List the role ids this host ships, then exit.
  --version          Print the installer version.
  --help             Show this help text.

Roles are never installed partially. If any destination fails preflight, nothing is
written; if a write fails partway through the run, everything this run created is
removed and everything it replaced is restored before it exits. A destination that exists but does not match a shipped or known-legacy
profile is a refusal, not an overwrite.

One customization is supported, because provider ids are per user: an installed profile
may add exactly one `model_provider = "<id>"` line. It is reported as CUSTOMIZED, passes
--check, and is never overwritten. Anything else differing is a conflict.
EOF
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  exit "${2:-1}"
}

preflight_failed=0
report_preflight_error() {
  printf '%s\n' "ERROR: $1" >&2
  preflight_failed=1
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk 'length($1) == 64 { print $1; exit }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk 'length($1) == 64 { print $1; exit }'
  fi
}

is_customized_with_provider() {
  dest=$1
  tmpl=$2

  [ "$(grep -c '^model_provider[[:space:]]*=' "$dest" 2>/dev/null || printf 0)" = "1" ] || return 1
  grep -Eq '^model_provider[[:space:]]*=[[:space:]]*"[A-Za-z0-9._-]+"[[:space:]]*$' "$dest" || return 1

  provider_line=$(grep -n '^model_provider[[:space:]]*=' "$dest" | head -1 | cut -d: -f1)
  [ -n "$provider_line" ] || return 1
  delimiters_before=$(head -n "$((provider_line - 1))" "$dest" | grep -c '"""' || true)
  [ $((delimiters_before % 2)) -eq 0 ] || return 1

  stripped=$(mktemp "${TMPDIR:-/tmp}/fablewright-strip.XXXXXX") || return 1
  grep -v '^model_provider[[:space:]]*=' "$dest" > "$stripped" 2>/dev/null
  if cmp -s "$tmpl" "$stripped"; then rm -f "$stripped"; return 0; fi
  rm -f "$stripped"
  return 1
}

rollback_created=''
rollback_pairs=''
rollback_dir=''

rollback_install() {
  [ -n "$rollback_created$rollback_pairs" ] || return 0
  printf '%s\n' "Rolling back this partial install." >&2

  if [ -n "$rollback_pairs" ]; then
    printf '%s\n' "$rollback_pairs" | while IFS='	' read -r dest backup; do
      [ -n "$dest" ] && [ -f "$backup" ] || continue
      if cp "$backup" "$dest" 2>/dev/null; then
        printf '%s\n' "RESTORED: $dest" >&2
      else
        printf '%s\n' "COULD NOT RESTORE: $dest (its previous content is at $backup)" >&2
      fi
    done
  fi

  if [ -n "$rollback_created" ]; then
    printf '%s\n' "$rollback_created" | while IFS= read -r created; do
      [ -n "$created" ] || continue
      if rm -f "$created" 2>/dev/null; then
        printf '%s\n' "REMOVED: $created" >&2
      else
        printf '%s\n' "COULD NOT REMOVE: $created" >&2
      fi
    done
  fi
  return 0
}

fail_rollback() {
  rollback_install
  fail "$1"
}

provider_of() {
  sed -n 's/^model_provider[[:space:]]*=[[:space:]]*"\([A-Za-z0-9._-]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

classify() {
  destination=$1
  template=$2
  role=$3

  if ! path_exists "$destination"; then
    printf '%s\n' missing
    return 0
  fi
  if [ -L "$destination" ] || [ ! -f "$destination" ]; then
    printf '%s\n' unsafe
    return 0
  fi
  if cmp -s "$template" "$destination"; then
    printf '%s\n' current
    return 0
  fi
  if is_customized_with_provider "$destination" "$template"; then
    printf '%s\n' customized
    return 0
  fi
  digest=$(sha256_file "$destination")
  if [ -z "$digest" ]; then
    printf '%s\n' unreadable
    return 0
  fi
  if [ -f "$legacy_digest_file" ] &&
    awk -v r="$role" -v d="$digest" '
      /^[[:space:]]*(#|$)/ { next }
      $1 == r && $2 == d { found = 1 }
      END { exit !found }
    ' "$legacy_digest_file"; then
    printf '%s\n' legacy
    return 0
  fi
  printf '%s\n' conflict
}

host=codex
target_dir=''
check_only=0
saw_customized=0
dry_run=0
list_only=0
check_roles=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [ "$#" -ge 2 ] || fail "--host requires a value: codex or claude-code." 64
      case "$2" in
        codex|claude-code) host=$2 ;;
        *) fail "unknown --host '$2'; expected codex or claude-code." 64 ;;
      esac
      shift 2
      ;;
    --target-dir)
      [ "$#" -ge 2 ] || fail "--target-dir requires a path." 64
      [ -n "$2" ] || fail "--target-dir requires a non-empty path." 64
      case "$2" in
        --*) fail "--target-dir path must be explicit; prefix an option-like relative name with ./ or use an absolute path." 64 ;;
      esac
      target_dir=$2
      shift 2
      ;;
    --check)
      check_only=1
      shift
      ;;
    --check-role)
      [ "$#" -ge 2 ] || fail "--check-role requires a role id (see --list)." 64
      [ -n "$2" ] || fail "--check-role requires a non-empty role id." 64
      case "$2" in
        *[!A-Za-z0-9_-]*) fail "--check-role accepts only letters, digits, '-' and '_' (got '$2')." 64 ;;
      esac
      check_only=1
      check_roles="$check_roles$2 "
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --list)
      list_only=1
      shift
      ;;
    --version)
      printf 'install-agents.sh %s\n' "$VERSION"
      exit 0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (run with --help for usage)." 64
      ;;
  esac
done

[ "$check_only" -eq 0 ] || [ "$dry_run" -eq 0 ] ||
  fail "--check and --dry-run are mutually exclusive; --check already mutates nothing." 64

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd) || fail "could not resolve the script directory."
template_dir=$script_dir/../hosts/$host/agents
legacy_digest_file=$script_dir/../hosts/$host/legacy-digests.txt

[ -d "$template_dir" ] || fail "no shipped profiles for host '$host' at $template_dir."

case "$host" in
  codex)
    template_glob='*.toml'
    default_dir=${CODEX_HOME:-${HOME:-}/.codex}/agents
    [ -n "${CODEX_HOME:-}${HOME:-}" ] || fail "set CODEX_HOME or HOME, or pass --target-dir." 64
    ;;
  claude-code)
    template_glob='*.md'
    default_dir=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/agents
    [ -n "${CLAUDE_CONFIG_DIR:-}${HOME:-}" ] || fail "set CLAUDE_CONFIG_DIR or HOME, or pass --target-dir." 64
    ;;
esac

roles=''
for template in "$template_dir"/$template_glob; do
  [ -e "$template" ] || continue
  base=${template##*/}
  case "$base" in
    fablewright-*) ;;
    *) continue ;;
  esac
  role=${base#fablewright-}
  role=${role%.*}
  [ -n "$role" ] || fail "shipped profile has an unusable name: $base"
  roles="$roles$role "
done

[ -n "$roles" ] || fail "no fablewright-* profiles found in $template_dir."

if [ "$list_only" -eq 1 ]; then
  printf '%s roles (%s):\n' "$host" "$template_dir"
  for role in $roles; do printf '  %s\n' "$role"; done
  exit 0
fi

resolved_roles=''
set -f
for requested in $check_roles; do
  matches=''
  match_count=0
  for role in $roles; do
    if [ "$role" = "$requested" ]; then
      matches=$role
      match_count=1
      break
    fi
    case "$role" in
      "$requested"*)
        matches="$matches$role "
        match_count=$((match_count + 1))
        ;;
    esac
  done
  case "$match_count" in
    0) fail "unknown role '$requested' for host $host. Run --list to see valid ids." 64 ;;
    1) resolved_roles="$resolved_roles$(printf '%s' "$matches" | awk '{print $1}') " ;;
    *) fail "role '$requested' is ambiguous for host $host; it matches: $matches. Name it exactly." 64 ;;
  esac
done
set +f

role_selected() {
  [ -n "$resolved_roles" ] || return 0
  for selected in $resolved_roles; do
    [ "$selected" = "$1" ] && return 0
  done
  return 1
}

[ -n "$target_dir" ] || target_dir=$default_dir
case "$target_dir" in
  /*) ;;
  *) target_dir=$(pwd -P)/$target_dir ;;
esac

target_parent=${target_dir%/*}
[ -n "$target_parent" ] || target_parent=/
target_leaf=${target_dir##*/}
if [ -d "$target_dir" ]; then
  resolved=$(CDPATH='' cd "$target_dir" 2>/dev/null && pwd -P) || resolved=''
  [ -n "$resolved" ] && target_dir=$resolved
elif [ -d "$target_parent" ]; then
  resolved_parent=$(CDPATH='' cd "$target_parent" 2>/dev/null && pwd -P) || resolved_parent=''
  if [ -n "$resolved_parent" ]; then
    case "$resolved_parent" in
      /) target_dir=/$target_leaf ;;
      *) target_dir=$resolved_parent/$target_leaf ;;
    esac
  fi
fi

case "$target_dir" in
  /|//|///*) fail "refusing to use the filesystem root as a target directory." ;;
esac
case "$target_dir" in
  */.|*/..|*/./*|*/../*) fail "target directory must not contain . or .. components: $target_dir" ;;
esac

for role in $roles; do
  for template in "$template_dir"/fablewright-"$role".*; do
    [ -f "$template" ] && [ ! -L "$template" ] ||
      fail "shipped profile is missing or not a regular file: $template"
  done
done

if path_exists "$target_dir" && { [ -L "$target_dir" ] || [ ! -d "$target_dir" ]; }; then
  report_preflight_error "target is not a real directory: $target_dir"
fi

template_for() {
  for candidate in "$template_dir"/fablewright-"$1".*; do
    [ -f "$candidate" ] && printf '%s\n' "$candidate" && return 0
  done
  return 1
}

states=''
for role in $roles; do
  template=$(template_for "$role") || fail "could not resolve a template for role $role."
  destination=$target_dir/${template##*/}
  state=$(classify "$destination" "$template" "$role")
  states="$states$role=$state "

  if [ "$check_only" -eq 1 ]; then
    role_selected "$role" || continue
    case "$state" in
      current) ;;
      customized)
        saw_customized=1
        printf '  CUSTOMIZED: %s pins model_provider="%s"; otherwise byte-exact.\n' \
          "$role" "$(provider_of "$destination")"
        ;;
      *) report_preflight_error "$role is $state, not the current exact profile: $destination" ;;
    esac
  else
    case "$state" in
      current|customized|legacy|missing) ;;
      *) report_preflight_error "$role destination is $state and will not be replaced: $destination" ;;
    esac
  fi
done

[ "$preflight_failed" -eq 0 ] || exit 1

state_of() {
  printf '%s' "$states" | tr ' ' '\n' | awk -F= -v r="$1" '$1 == r { print $2; exit }'
}

if [ "$check_only" -eq 1 ]; then
  if [ -n "$resolved_roles" ]; then
    if [ "$saw_customized" -eq 1 ]; then
      printf 'CHECK PASSED: %s matches %s, apart from the provider customization listed above\n' "$(printf '%s' "$resolved_roles" | sed 's/ *$//')" "$template_dir"
    else
      printf 'CHECK PASSED: %s matches %s exactly\n' "$(printf '%s' "$resolved_roles" | sed 's/ *$//')" "$template_dir"
    fi
  else
    if [ "$saw_customized" -eq 1 ]; then
      printf 'CHECK PASSED: all %s roles match %s, apart from the provider customizations listed above\n' "$host" "$template_dir"
    else
      printf 'CHECK PASSED: all %s roles match %s exactly\n' "$host" "$template_dir"
    fi
  fi
  exit 0
fi

if [ "$dry_run" -eq 1 ]; then
  path_exists "$target_dir" || printf 'Would create directory: %s\n' "$target_dir"
  for role in $roles; do
    template=$(template_for "$role")
    destination=$target_dir/${template##*/}
    case "$(state_of "$role")" in
      missing) printf 'Would install: %s\n' "$destination" ;;
      legacy)  printf 'Would migrate exact legacy profile: %s\n' "$destination" ;;
      current) printf 'Already current: %s\n' "$destination" ;;
      customized) printf 'Leaving your provider customization in place: %s\n' "$destination" ;;
    esac
  done
  exit 0
fi

if [ ! -d "$target_dir" ]; then
  mkdir -p "$target_dir" || fail "could not create target directory: $target_dir"
fi

staged=''
cleanup_staged() {
  if [ -n "${staged:-}" ] && [ -f "$staged" ]; then
    case "$staged" in
      "$target_dir"/.fablewright-agent.*) rm -f "$staged" ;;
    esac
  fi
  return 0
}
trap cleanup_staged 0 HUP INT TERM
[ -d "$target_dir" ] && [ ! -L "$target_dir" ] ||
  fail "target directory changed after preflight: $target_dir"

for role in $roles; do
  template=$(template_for "$role")
  destination=$target_dir/${template##*/}
  expected=$(state_of "$role")
  actual=$(classify "$destination" "$template" "$role")
  [ "$expected" = "$actual" ] ||
    fail "$role changed after preflight (was $expected, now $actual); no destination was modified."
done

for role in $roles; do
  template=$(template_for "$role")
  destination=$target_dir/${template##*/}
  state=$(state_of "$role")
  staged=''

  case "$state" in
    current)
      printf 'ALREADY CURRENT: %s\n' "$destination"
      continue
      ;;
    customized)
      saw_customized=1
      printf 'ALREADY CURRENT (with your model_provider="%s"): %s\n' \
        "$(provider_of "$destination")" "$destination"
      continue
      ;;
    missing|legacy) ;;
    *) fail "$role is $state at mutation time; refusing to write $destination." ;;
  esac

  staged=$(mktemp "$target_dir/.fablewright-agent.XXXXXX") ||
    fail_rollback "could not stage profile for $role."
  if ! cp "$template" "$staged"; then
    rm -f "$staged"
    fail_rollback "could not stage profile for $role."
  fi

  if [ "$(classify "$destination" "$template" "$role")" != "$state" ]; then
    rm -f "$staged"
    fail_rollback "$destination changed during installation and will not be overwritten."
  fi

  if [ "$state" = missing ]; then
    if ! ln "$staged" "$destination" 2>/dev/null; then
      rm -f "$staged"
      fail_rollback "$destination appeared during installation and will not be overwritten."
    fi
    rm -f "$staged"
    rollback_created="$rollback_created$destination
"
    printf 'INSTALLED: %s\n' "$destination"
  else
    if [ -z "$rollback_dir" ]; then
      rollback_dir=$(mktemp -d "${TMPDIR:-/tmp}/fablewright-rollback.XXXXXX") ||
        fail_rollback "could not create a rollback directory."
    fi
    backup=$rollback_dir/${destination##*/}
    if ! cp "$destination" "$backup"; then
      rm -f "$staged"
      fail_rollback "could not back up $destination before migrating it."
    fi
    if ! mv -f "$staged" "$destination"; then
      rm -f "$staged"
      fail_rollback "could not migrate exact legacy profile: $destination"
    fi
    rollback_pairs="$rollback_pairs$destination	$backup
"
    printf 'MIGRATED: %s\n' "$destination"
  fi

  if [ -n "${FABLEWRIGHT_TEST_FAIL_AFTER:-}" ]; then
    written=$((${written:-0} + 1))
    if [ "$written" -ge "$FABLEWRIGHT_TEST_FAIL_AFTER" ]; then
      fail_rollback "FABLEWRIGHT_TEST_FAIL_AFTER=$FABLEWRIGHT_TEST_FAIL_AFTER reached; aborting to exercise rollback."
    fi
  fi
done

for role in $roles; do
  template=$(template_for "$role")
  destination=$target_dir/${template##*/}
  case "$(classify "$destination" "$template" "$role")" in
    current|customized) ;;
    *) fail "post-install exactness check failed: $destination" ;;
  esac
done

[ -n "$rollback_dir" ] && rm -rf "$rollback_dir"

if [ "$saw_customized" -eq 1 ]; then
  printf 'INSTALL PASSED: all %s roles match %s, apart from the provider customizations reported above\n' \
    "$host" "$template_dir"
else
  printf 'INSTALL PASSED: all %s roles match %s exactly\n' "$host" "$template_dir"
fi
