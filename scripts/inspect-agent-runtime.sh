#!/bin/sh

set -eu

VERSION=1.0.0

usage() {
  cat <<'EOF'
Usage: inspect-agent-runtime.sh [--sessions-dir DIR] [--require-role ROLE] THREAD_ID

Read the one rollout file whose name ends with THREAD_ID and emit a compact JSON object
containing only safe routing metadata. Without --sessions-dir, the sessions root is
"$CODEX_HOME/sessions" when CODEX_HOME is set, otherwise "$HOME/.codex/sessions".

Emitted fields: thread_id, parent_thread_id, agent_role, agent_path, model_provider,
model, effort, efforts, sandbox_policy_type, permission_profile_type, cwd, turns.

`model` must be identical across every turn of the thread or the tool refuses: a thread
that changed model mid-flight has unverifiable routing. `effort` reports the most recent
turn and `efforts` lists every distinct value observed, because a host may legitimately
vary effort per turn.

`agent_role` is null for a top-level thread, such as one started by `codex exec`, and is
set only for a spawned custom agent. Pass --require-role ROLE to assert a specific named
custom agent; without it, a null role is reported rather than refused.

Exit codes: 0 ok, 2 usage, 1 refusal (no match, ambiguous match, missing or
inconsistent required routing metadata).
EOF
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  exit "${2:-1}"
}

sessions_dir=''
require_role=''
thread_id=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sessions-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--sessions-dir requires a non-empty directory." 2
      sessions_dir=$2
      shift 2
      ;;
    --require-role)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--require-role requires a role name." 2
      require_role=$2
      shift 2
      ;;
    --version)
      printf 'inspect-agent-runtime.sh %s\n' "$VERSION"
      exit 0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      [ -z "$thread_id" ] || { usage >&2; exit 2; }
      thread_id=$1
      shift
      ;;
  esac
done

[ -n "$thread_id" ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || fail "jq is not on PATH." 1

printf '%s\n' "$thread_id" | LC_ALL=C grep -Eq \
  '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ||
  fail "THREAD_ID must be a lowercase UUID." 2

if [ -z "$sessions_dir" ]; then
  if [ -n "${CODEX_HOME-}" ]; then
    sessions_dir=$CODEX_HOME/sessions
  else
    [ -n "${HOME-}" ] || fail "HOME is unset and CODEX_HOME was not supplied; pass --sessions-dir." 2
    sessions_dir=$HOME/.codex/sessions
  fi
fi
[ -d "$sessions_dir" ] || fail "sessions directory is unavailable." 1

tmp_base=${TMPDIR:-/tmp}
case "$tmp_base" in
  /*) ;;
  *) tmp_base=/tmp ;;
esac
matches_file=''
cleanup() {
  if [ -n "$matches_file" ] && [ -f "$matches_file" ]; then
    case "$matches_file" in
      "$tmp_base"/fablewright-runtime.*) rm -f "$matches_file" ;;
      *) printf '%s\n' "ERROR: refusing cleanup of an unexpected temporary file." >&2 ;;
    esac
  fi
  return 0
}
trap cleanup 0 HUP INT TERM

matches_file=$(mktemp "$tmp_base/fablewright-runtime.XXXXXX") ||
  fail "could not create a temporary match list." 1

find "$sessions_dir" -type f -name "rollout-*-$thread_id.jsonl" -print > "$matches_file" ||
  fail "could not enumerate rollout filenames." 1

match_count=$(awk 'END { print NR + 0 }' "$matches_file")
case "$match_count" in
  0) fail "no rollout filename matched the requested thread id." 1 ;;
  1) ;;
  *) fail "multiple rollout filenames matched the requested thread id." 1 ;;
esac

IFS= read -r rollout_file < "$matches_file" || fail "could not read the matched filename." 1
[ -f "$rollout_file" ] || fail "matched rollout is unavailable." 1

if ! jq -ce -s --arg want "$thread_id" --arg require_role "$require_role" '
  def s: if type == "string" and length > 0 then . else null end;
  def policy_type:
    if type == "object" then (.type | s)
    elif type == "string" then s
    else null end;

  [ .[] | select(.type == "session_meta") | .payload | select((.id | s) == $want) ] as $meta |
  [ .[] | select(.type == "turn_context") | .payload ] as $turns |

  if ($meta | length) == 0 then
    error("no session metadata identifies the requested thread")
  elif ($meta | length) > 1 then
    error("duplicate session metadata for the requested thread")
  elif ($turns | length) == 0 then
    error("missing turn context")
  else
    $meta[0] as $m |
    [ $turns[] | (.model | s) ] as $models |
    [ $turns[] | (.effort | s) ] as $efforts |
    [ $turns[] | (.sandbox_policy | policy_type) ] as $sandboxes |
    [ $turns[] | (.permission_profile | policy_type) ] as $permissions |
    [ $turns[] | (.cwd | s) ] as $cwds |

    if $require_role != "" and ($m.agent_role | s) != $require_role then
      error("thread role is not the required custom agent")
    elif any($models[]; . == null) then error("missing model")
    elif ($models | unique | length) != 1 then error("conflicting models across turns")
    elif any($efforts[]; . == null) then error("missing effort")
    elif any($sandboxes[]; . == null) then error("missing sandbox policy")
    elif ($sandboxes | unique | length) != 1 then error("conflicting sandbox policies across turns")
    elif any($permissions[]; . == null) then error("missing permission profile")
    elif ($permissions | unique | length) != 1 then error("conflicting permission profiles across turns")
    elif any($cwds[]; . == null) then error("missing working directory")
    elif ($cwds | unique | length) != 1 then error("conflicting working directories across turns")
    else
      {
        thread_id:              ($m.id | s),
        parent_thread_id:       ($m.parent_thread_id | s),
        agent_role:             ($m.agent_role | s),
        agent_path:             ($m.agent_path | s),
        model_provider:         ($m.model_provider | s),
        model:                  $models[0],
        effort:                 $efforts[-1],
        efforts:                ($efforts | unique),
        sandbox_policy_type:    $sandboxes[0],
        permission_profile_type: $permissions[0],
        cwd:                    $cwds[0],
        turns:                  ($turns | length)
      }
    end
  end
' "$rollout_file" 2>/dev/null; then
  fail "rollout is missing, ambiguous, or inconsistent in its required routing metadata." 1
fi
