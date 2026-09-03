#!/bin/sh

set -eu

VERSION=1.0.0

usage() {
  cat <<'EOF'
Usage: cast-call.sh --lane ROLE [options] < specification

Run one FABLEWRIGHT cast lane and return its report plus proof of how it was routed.
The five-part specification is read from stdin.

  --lane ROLE        Required. Lane id (luna, terra, flash, glm) or a full role id.
  --kind KIND        implementer (default) or reviewer. Selects which profile a bare
                     lane id resolves to, so `--lane glm` is never ambiguous.
  --cwd DIR          Working root for the worker. Default: current directory.
  --profile-dir DIR  Lane profile directory. Default: <repo>/hosts/codex/agents.
  --sandbox MODE     Narrow the profile sandbox: read-only, workspace-write, or
                     danger-full-access. It may only narrow, never widen: a lane pinned
                     to read-only cannot be run with a wider sandbox. The override is
                     reported, never hidden.
  --provider ID      Codex model_provider id to serve this lane. Overrides the lane
                     profile's own model_provider pin and the mapping in
                     <profile-dir>/../lane-providers.tsv, in that order. Needed for
                     lanes whose model the host default provider does not serve. The
                     sidecar map is repo-relative, so after installing profiles into
                     CODEX_HOME the durable option is the profile's own model_provider.
  --report FILE      Also write the worker's final message to FILE.
  --check            Validate the lane profile and the runtime, run no model, exit.
  --dry-run          Print the exact command that would run, run no model, exit.
  --ephemeral        Do not persist session files. This DISABLES routing proof; the
                     script says so and exits 75 rather than claiming a verified route.
  --hermetic         Do not load the host config.toml. Removes host MCP servers and
                     hooks from the run - and also any custom model provider, so the
                     flash and glm lanes will not resolve under it.
  --version          Print the version.
  --help             Show this help.

Exit codes: 0 the lane ran and its routing was verified, 64 usage, 69 lane unavailable
or routing unproven, 70 the worker ran but failed, 75 the lane ran and returned a report
but routing was waived (--ephemeral), 127 a dependency is missing.

Exit 0 means verified. A caller gating on `$? -eq 0` will therefore never mistake a
waived run for a proven one.
EOF
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  exit "${2:-69}"
}

toml_scalar() {
  awk -v key="$2" '
    function delims(s,   n, i) {
      n = 0
      while ((i = index(s, "\"\"\"")) > 0) { n++; s = substr(s, i + 3) }
      return n
    }
    BEGIN { in_block = 0; done = 0; found = 0 }
    {
      d = delims($0)
      if (!in_block && !done && !found) {
        if ($0 ~ /^[[:space:]]*\[/) {
          done = 1
        } else if ($0 ~ ("^[[:space:]]*" key "[[:space:]]*=")) {
          rest = $0
          sub(/^[^=]*=[[:space:]]*/, "", rest)
          if (substr(rest, 1, 1) == "\"") {
            rest = substr(rest, 2)
            q = index(rest, "\"")
            if (q > 0) { print substr(rest, 1, q - 1); found = 1 }
          }
        }
      }
      if (d % 2 == 1) in_block = !in_block
    }
  ' "$1"
}

toml_multiline() {
  awk -v key="$2" '
    !inblock && $0 ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*\"\"\"[[:space:]]*$" {
      inblock = 1
      next
    }
    inblock && $0 ~ /^[[:space:]]*"""[[:space:]]*$/ { exit }
    inblock { print }
  ' "$1"
}

lane=''
kind=implementer
worker_cwd=''
profile_dir=''
sandbox_override=''
provider=''
report_file=''
check_only=0
dry_run=0
ephemeral=0
hermetic=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane)        [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--lane requires a role id." 64; lane=$2; shift 2 ;;
    --kind)
      [ "$#" -ge 2 ] || fail "--kind requires implementer or reviewer." 64
      case "$2" in
        implementer|reviewer) kind=$2 ;;
        *) fail "--kind must be implementer or reviewer (got '$2')." 64 ;;
      esac
      shift 2
      ;;
    --cwd)         [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--cwd requires a directory." 64; worker_cwd=$2; shift 2 ;;
    --profile-dir) [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--profile-dir requires a directory." 64; profile_dir=$2; shift 2 ;;
    --sandbox)
      [ "$#" -ge 2 ] || fail "--sandbox requires a mode." 64
      case "$2" in
        read-only|workspace-write|danger-full-access) sandbox_override=$2 ;;
        *) fail "--sandbox must be read-only, workspace-write, or danger-full-access (got '$2')." 64 ;;
      esac
      shift 2
      ;;
    --provider)    [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--provider requires a provider id." 64; provider=$2; shift 2 ;;
    --report)      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--report requires a path." 64; report_file=$2; shift 2 ;;
    --check)       check_only=1; shift ;;
    --dry-run)     dry_run=1; shift ;;
    --ephemeral)   ephemeral=1; shift ;;
    --hermetic)    hermetic=1; shift ;;
    --version)     printf 'cast-call.sh %s\n' "$VERSION"; exit 0 ;;
    --help|-h)     usage; exit 0 ;;
    *)             fail "unknown argument: $1 (run with --help for usage)." 64 ;;
  esac
done

[ -n "$lane" ] || fail "--lane is required (luna, terra, flash, glm)." 64

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd) || fail "could not resolve the script directory."
[ -n "$profile_dir" ] || profile_dir=$script_dir/../hosts/codex/agents
[ -d "$profile_dir" ] || fail "lane profile directory does not exist: $profile_dir" 64

profile=''
match_count=0

prefix_profile=''
prefix_count=0
prefix_names=''

for candidate in "$profile_dir"/fablewright-*.toml; do
  [ -f "$candidate" ] || continue
  base=${candidate##*/}
  role=${base#fablewright-}
  role=${role%.toml}
  if [ "$role" = "$lane" ] || [ "$role" = "$lane-$kind" ]; then
    profile=$candidate
    match_count=1

    break
  fi
  case "$role" in
    "$lane"*"-$kind")
      prefix_profile=$candidate
      prefix_count=$((prefix_count + 1))
      prefix_names="$prefix_names$role "
      ;;
  esac
done

if [ "$match_count" -eq 0 ]; then
  case "$prefix_count" in
    0) fail "unknown lane '$lane' for kind $kind. Available profiles are in $profile_dir." 64 ;;
    1) profile=$prefix_profile ;;
    *) fail "lane '$lane' is ambiguous for kind $kind; it matches: $prefix_names. Name it exactly." 64 ;;
  esac
fi

[ -L "$profile" ] && fail "lane profile is a symlink and will not be trusted: $profile" 69
model=$(toml_scalar "$profile" model)
effort=$(toml_scalar "$profile" model_reasoning_effort)
sandbox=$(toml_scalar "$profile" sandbox_mode)
role_name=$(toml_scalar "$profile" name)
profile_provider=$(toml_scalar "$profile" model_provider)
instructions=$(toml_multiline "$profile" developer_instructions)

[ -n "$model" ] || fail "lane profile does not pin a model: $profile" 69
[ -n "$instructions" ] || fail "lane profile has no developer_instructions: $profile" 69
provider_source='host default'
if [ -n "$provider" ]; then
  provider_source='--provider'
elif [ -n "$profile_provider" ]; then
  provider=$profile_provider
  provider_source='lane profile'
else
  provider_map=$profile_dir/../lane-providers.tsv
  if [ -f "$provider_map" ] && [ ! -L "$provider_map" ]; then
    resolved_role=${profile##*/}
    resolved_role=${resolved_role#fablewright-}
    resolved_role=${resolved_role%.toml}
    provider=$(awk -v r="$resolved_role" '
      /^[[:space:]]*(#|$)/ { next }
      $1 == r { print $2; exit }
    ' "$provider_map")
    [ -n "$provider" ] && provider_source='lane-providers.tsv'
  fi
fi

sandbox_rank() {
  case "$1" in
    read-only) printf '0\n' ;;
    workspace-write) printf '1\n' ;;
    danger-full-access) printf '2\n' ;;
    *) printf '3\n' ;;
  esac
}
if [ -n "$sandbox_override" ]; then
  if [ -n "$sandbox" ] && [ "$(sandbox_rank "$sandbox_override")" -gt "$(sandbox_rank "$sandbox")" ]; then
    fail "lane $lane pins sandbox '$sandbox'; --sandbox $sandbox_override would widen it. A lane that needs a wider sandbox is a different lane." 64
  fi
  sandbox=$sandbox_override
fi
[ -n "$sandbox" ] || sandbox=workspace-write
[ -n "$worker_cwd" ] || worker_cwd=$(pwd -P)
[ -d "$worker_cwd" ] || fail "--cwd is not a directory: $worker_cwd" 64

if [ "$check_only" -eq 1 ]; then
  printf 'CHECK PASSED: lane %s -> role=%s model=%s effort=%s sandbox=%s\n' \
    "$lane" "${role_name:-unset}" "$model" "${effort:-provider-default}" "$sandbox"
  printf '  provider: %s (%s)\n' "${provider:-inherited}" "$provider_source"
  printf '  profile: %s\n' "$profile"
  printf '  note: this validates the pin, not that the provider can serve it. A run proves that.\n'
  exit 0
fi

set -- exec -m "$model" -s "$sandbox" -C "$worker_cwd" --skip-git-repo-check --json
[ -n "$effort" ] && set -- "$@" -c "model_reasoning_effort=$effort"
[ -n "$provider" ] && set -- "$@" -c "model_provider=$provider"
[ "$ephemeral" -eq 1 ] && set -- "$@" --ephemeral
[ "$hermetic" -eq 1 ] && set -- "$@" --ignore-user-config

if [ "$dry_run" -eq 1 ]; then
  printf 'Would run: codex'
  for arg in "$@"; do printf ' %s' "$arg"; done
  printf ' -o <report> -\n'
  printf 'Prompt would be: %s standing instructions + the specification on stdin.\n' "${role_name:-$lane}"
  printf 'Provider: %s (%s)\n' "${provider:-inherited from host}" "$provider_source"
  exit 0
fi

command -v codex >/dev/null 2>&1 || fail "the Codex CLI is not on PATH." 127
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH; FABLEWRIGHT needs it to verify routing." 127

spec=$(cat)
case "$spec" in
  *[![:space:]]*) ;;
  *) fail "provide a five-part specification on stdin." 64 ;;
esac

tmp_base=${TMPDIR:-/tmp}
case "$tmp_base" in /*) ;; *) tmp_base=/tmp ;; esac
work=$(mktemp -d "$tmp_base/fablewright-cast.XXXXXX") || fail "could not create a temporary directory." 69
cleanup() {
  if [ -n "${work:-}" ]; then rm -rf "$work"; fi
  return 0
}
trap cleanup 0 HUP INT TERM

printf '%s\n\n---\n\n%s\n' "$instructions" "$spec" > "$work/prompt.txt"

set +e
codex "$@" -o "$work/report.txt" - < "$work/prompt.txt" > "$work/events.jsonl" 2>"$work/stderr.txt"
run_status=$?
set -e

thread_id=$(jq -r 'select(.type == "thread.started") | .thread_id // empty' "$work/events.jsonl" 2>/dev/null | head -1)

if [ "$run_status" -ne 0 ]; then
  printf 'ERROR: the %s lane failed (codex exited %s).\n' "$lane" "$run_status" >&2
  printf '  pinned: model=%s effort=%s provider=%s sandbox=%s\n' "$model" "${effort:-provider-default}" "${provider:-host default}" "$sandbox" >&2
  [ -n "$thread_id" ] && printf '  thread_id: %s\n' "$thread_id" >&2

  signal=$(grep -vE 'rmcp::transport|AuthRequiredError|Transport channel closed' "$work/stderr.txt" 2>/dev/null |
    grep -vE '^[[:space:]]*$' | tail -5)
  if [ -n "$signal" ]; then
    printf '  cause:\n' >&2
    printf '%s\n' "$signal" | sed 's/^/    /' >&2
  else
    printf '  cause: the runtime printed no diagnostic beyond unrelated MCP transport errors.\n' >&2
  fi

  if [ -s "$work/stderr.txt" ]; then
    if kept=$(mktemp "$tmp_base/fablewright-cast-stderr.XXXXXX" 2>/dev/null); then
      if cat "$work/stderr.txt" > "$kept" 2>/dev/null; then
        printf '  full stderr: %s (delete it when you are done)\n' "$kept" >&2
      else
        rm -f "$kept"
      fi
    fi
  fi

  [ "$sandbox" = "read-only" ] ||
    printf '  WARNING: it ran with sandbox=%s and may have modified %s before failing.\n' "$sandbox" "$worker_cwd" >&2
  printf '  This lane is stopped. FABLEWRIGHT does not re-route stopped work to another lane.\n' >&2
  exit 70
fi

if [ ! -s "$work/report.txt" ]; then
  printf '%s\n' "ERROR: the $lane lane returned no report." >&2
  [ "$sandbox" = "read-only" ] || printf '  WARNING: it ran with sandbox=%s and may still have modified %s.\n' "$sandbox" "$worker_cwd" >&2
  exit 70
fi

warn_possible_mutation() {
  [ "$sandbox" = "read-only" ] && return 0
  printf '  WARNING: this lane ran with sandbox=%s, so it may already have modified\n' "$sandbox" >&2
  printf '           %s. Inspect the working tree before continuing; the report is\n' "$worker_cwd" >&2
  printf '           refused, but any changes it made are still on disk.\n' >&2
  return 0
}

refuse_routing() {
  printf '%s\n' "ERROR: $1" >&2
  warn_possible_mutation
  exit 69
}

routing_proof='unverified'
if [ "$ephemeral" -eq 1 ]; then
  routing_proof='waived (--ephemeral persists no session, so the route cannot be proven)'
elif [ -z "$thread_id" ]; then
  refuse_routing "no thread id was emitted, so the route cannot be proven. Refusing to present unverified work as routed."
else
  observed=$("$script_dir/inspect-agent-runtime.sh" "$thread_id" 2>/dev/null) ||
    refuse_routing "routing evidence for thread $thread_id is unavailable. Refusing to present unverified work as routed."
  observed_model=$(printf '%s' "$observed" | jq -r '.model')
  observed_effort=$(printf '%s' "$observed" | jq -r '.effort')
  observed_sandbox=$(printf '%s' "$observed" | jq -r '.sandbox_policy_type')
  observed_provider=$(printf '%s' "$observed" | jq -r '.model_provider // "unknown"')
  observed_turns=$(printf '%s' "$observed" | jq -r '.turns')

  checked="model=$observed_model sandbox=$observed_sandbox"
  unpinned=""

  [ "$observed_model" = "$model" ] ||
    refuse_routing "lane $lane was pinned to '$model' but thread $thread_id ran '$observed_model'. FABLEWRIGHT does not accept a substituted worker."
  [ "$observed_sandbox" = "$sandbox" ] ||
    refuse_routing "lane $lane requested sandbox '$sandbox' but thread $thread_id observed '$observed_sandbox'."

  if [ -n "$effort" ]; then
    off_pin=$(printf '%s' "$observed" | jq -r --arg want "$effort" \
      '[.efforts[] | select(. != $want)] | unique | join(", ")')
    [ -z "$off_pin" ] ||
      refuse_routing "lane $lane was pinned to effort '$effort' but thread $thread_id also ran at: $off_pin (across $observed_turns turns)."
    checked="$checked effort=$effort(all $observed_turns turns)"
  else
    unpinned="$unpinned effort=$observed_effort"
  fi

  if [ -n "$provider" ]; then
    [ "$observed_provider" = "$provider" ] ||
      refuse_routing "lane $lane requested provider '$provider' but thread $thread_id was served by '$observed_provider'."
    checked="$checked provider=$observed_provider"
  else
    unpinned="$unpinned provider=$observed_provider"
  fi

  if [ -n "$unpinned" ]; then
    routing_proof="verified [$checked]; observed but NOT pinned, so NOT checked:$unpinned; thread=$thread_id"
  else
    routing_proof="verified [$checked]; thread=$thread_id"
  fi
fi

printf 'FABLEWRIGHT CAST REPORT — lane %s (%s)\n' "$lane" "${role_name:-unpinned role}"
printf 'routing: %s\n\n' "$routing_proof"
cat "$work/report.txt"
printf '\n'

if [ "$ephemeral" -eq 1 ]; then
  waived_exit=75
else
  waived_exit=0
fi

if [ -n "$report_file" ]; then
  if [ -L "$report_file" ]; then
    printf 'ERROR: --report path is a symlink and will not be written: %s\n' "$report_file" >&2
    exit 64
  fi
  if [ -e "$report_file" ] && [ ! -f "$report_file" ]; then
    printf 'ERROR: --report path exists and is not a regular file: %s\n' "$report_file" >&2
    exit 64
  fi
  if ! cp "$work/report.txt" "$report_file"; then
    printf 'ERROR: could not write the report to %s. The report above is still valid.\n' "$report_file" >&2
    exit 64
  fi
fi

exit "$waived_exit"
