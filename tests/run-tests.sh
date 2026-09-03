#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$repo_root"

pass=0
fail=0

ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  if [ -n "${2-}" ]; then printf '       %s\n' "$2"; fi
  return 0
}
group(){ printf '\n%s\n' "$1"; }

expect_status() {
  expected=$1; label=$2; shift 2
  set +e
  out=$("$@" 2>&1)
  actual=$?
  set -e
  if [ "$actual" -eq "$expected" ]; then
    ok "$label"
  else
    bad "$label" "expected exit $expected, got $actual: $(printf '%s' "$out" | head -1)"
  fi
}

expect_output_status() {
  expected=$1; needle=$2; label=$3; shift 3
  set +e
  out=$("$@" 2>&1)
  actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then
    bad "$label" "expected exit $expected, got $actual: $(printf '%s' "$out" | head -1)"
    return 0
  fi
  case "$out" in
    *"$needle"*) ok "$label" ;;
    *) bad "$label" "expected to see '$needle', got: $(printf '%s' "$out" | head -1)" ;;
  esac
}

expect_output() {
  needle=$1; label=$2; shift 2
  expect_output_status 0 "$needle" "$label" "$@"
}

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/fablewright-tests.XXXXXX")
cleanup() { rm -rf "$tmp_root"; }
trap cleanup 0 HUP INT TERM

fixtures=tests/fixtures/sessions

group 'shell syntax'
for script in scripts/*.sh tests/*.sh; do
  expect_status 0 "sh -n $script" sh -n "$script"
done

group 'scripts are executable'
for script in scripts/*.sh; do
  if [ -x "$script" ]; then ok "$script is executable"; else bad "$script is executable"; fi
done

group 'runtime inspector'
expect_status 0 'nominal subagent thread is accepted' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
expect_output '"model":"gpt-5.6-luna"' 'reports the pinned model' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
expect_output '"efforts":["max","ultra"]' 'reports every distinct effort observed' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
expect_output '"agent_role":"fablewright_luna_implementer"' 'selects the requested thread, not its parent' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
expect_status 0 'top-level thread with a null agent_role is accepted' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" 11111111-2222-3333-4444-555555555555
expect_output '"sandbox_policy_type":"read-only"' 'accepts a bare-string sandbox policy' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" 11111111-2222-3333-4444-555555555555
expect_status 0 '--require-role matches the actual role' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" --require-role fablewright_luna_implementer aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
expect_status 1 '--require-role refuses a different role' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" --require-role fablewright_terra_implementer aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
expect_status 1 'a thread that changed model mid-flight is refused' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" 99999999-8888-7777-6666-555555555555
expect_status 1 'a thread with no turn context is refused' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" abcdefab-cdef-abcd-efab-cdefabcdefab
expect_status 1 'an unknown thread is refused' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" 00000000-0000-0000-0000-000000000000
expect_status 2 'a malformed thread id is rejected' \
  ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" not-a-uuid
if ./scripts/inspect-agent-runtime.sh --sessions-dir "$fixtures" \
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 2>/dev/null | grep -q 'must never be emitted'; then
  bad 'never emits rollout payload content'
else
  ok 'never emits rollout payload content'
fi

group 'installer: codex host'
codex_dir=$tmp_root/codex-agents
expect_output 'luna-implementer' 'lists codex roles' \
  ./scripts/install-agents.sh --host codex --list
expect_status 0 'dry-run succeeds' \
  ./scripts/install-agents.sh --target-dir "$codex_dir" --dry-run
if [ -e "$codex_dir" ]; then bad 'dry-run creates nothing'; else ok 'dry-run creates nothing'; fi
expect_status 0 'install succeeds' ./scripts/install-agents.sh --target-dir "$codex_dir"
expect_status 0 'install is idempotent' ./scripts/install-agents.sh --target-dir "$codex_dir"
expect_status 0 'check passes after install' ./scripts/install-agents.sh --target-dir "$codex_dir" --check
for profile in hosts/codex/agents/*.toml; do
  base=${profile##*/}
  if cmp -s "$profile" "$codex_dir/$base"; then
    ok "installed copy is byte-identical: $base"
  else
    bad "installed copy is byte-identical: $base"
  fi
done

group 'installer: refusals'
printf '\n# hand edited\n' >> "$codex_dir/fablewright-luna-implementer.toml"
before=$(cd "$codex_dir" && shasum -a 256 ./* | shasum -a 256)
expect_status 1 'check fails on a modified profile' \
  ./scripts/install-agents.sh --target-dir "$codex_dir" --check
expect_status 1 'install refuses a modified profile' \
  ./scripts/install-agents.sh --target-dir "$codex_dir"
after=$(cd "$codex_dir" && shasum -a 256 ./* | shasum -a 256)
if [ "$before" = "$after" ]; then
  ok 'a refused install modifies no file at all'
else
  bad 'a refused install modifies no file at all'
fi
cp hosts/codex/agents/fablewright-luna-implementer.toml "$codex_dir/fablewright-luna-implementer.toml"

rm -f "$codex_dir/fablewright-sol-reviewer.toml"
ln -s /etc/hosts "$codex_dir/fablewright-sol-reviewer.toml"
expect_status 1 'install refuses a symlinked destination' \
  ./scripts/install-agents.sh --target-dir "$codex_dir"
if [ "$(readlink "$codex_dir/fablewright-sol-reviewer.toml")" = /etc/hosts ]; then
  ok 'a symlinked destination is neither followed nor replaced'
else
  bad 'a symlinked destination is neither followed nor replaced'
fi
rm -f "$codex_dir/fablewright-sol-reviewer.toml"

not_a_dir=$tmp_root/not-a-dir
: > "$not_a_dir"
expect_status 1 'install refuses a non-directory target' \
  ./scripts/install-agents.sh --target-dir "$not_a_dir"
expect_status 1 'install refuses the filesystem root' \
  ./scripts/install-agents.sh --target-dir /
expect_status 64 'unknown role is rejected' \
  ./scripts/install-agents.sh --target-dir "$codex_dir" --check-role nope
expect_status 64 'ambiguous role prefix is rejected' \
  ./scripts/install-agents.sh --target-dir "$codex_dir" --check-role glm
expect_status 64 'unknown host is rejected' \
  ./scripts/install-agents.sh --host nope --list
expect_status 64 '--check and --dry-run are mutually exclusive' \
  ./scripts/install-agents.sh --target-dir "$codex_dir" --check --dry-run

group 'installer: claude-code host'
cc_dir=$tmp_root/claude-agents
expect_status 0 'install succeeds' ./scripts/install-agents.sh --host claude-code --target-dir "$cc_dir"
expect_status 0 'check passes' ./scripts/install-agents.sh --host claude-code --target-dir "$cc_dir" --check
for profile in hosts/claude-code/agents/*.md; do
  base=${profile##*/}
  if cmp -s "$profile" "$cc_dir/$base"; then
    ok "installed copy is byte-identical: $base"
  else
    bad "installed copy is byte-identical: $base"
  fi
done

group 'installer: a provider pin is a supported customization'
prov_dir=$tmp_root/prov-agents
./scripts/install-agents.sh --target-dir "$prov_dir" >/dev/null
printf 'model_provider = "zai"\n' >> "$prov_dir/fablewright-glm-implementer.toml"
expect_status 0 'one appended model_provider line still passes --check' \
  ./scripts/install-agents.sh --target-dir "$prov_dir" --check
expect_output 'CUSTOMIZED: glm-implementer' 'the customization is reported, not hidden' \
  ./scripts/install-agents.sh --target-dir "$prov_dir" --check
expect_status 0 'install leaves a customized profile alone' \
  ./scripts/install-agents.sh --target-dir "$prov_dir"
if grep -q 'model_provider = "zai"' "$prov_dir/fablewright-glm-implementer.toml"; then
  ok 'the provider pin survives a reinstall'
else
  bad 'the provider pin survives a reinstall'
fi
printf 'model_provider = "second"\n' >> "$prov_dir/fablewright-glm-implementer.toml"
expect_status 1 'two provider lines are a conflict, not a customization' \
  ./scripts/install-agents.sh --target-dir "$prov_dir" --check-role glm-implementer
sed -i.bak '/model_provider = "second"/d' "$prov_dir/fablewright-glm-implementer.toml"
rm -f "$prov_dir/fablewright-glm-implementer.toml.bak"
printf '# a real edit\n' >> "$prov_dir/fablewright-terra-implementer.toml"
expect_status 1 'any other edit is still a conflict' \
  ./scripts/install-agents.sh --target-dir "$prov_dir" --check-role terra

smuggle=$tmp_root/smuggle
mkdir -p "$smuggle"
cp hosts/codex/agents/fablewright-glm-implementer.toml "$smuggle/"
awk '/^developer_instructions/ { print; getline; print; print "model_provider = \"zai\""; next } { print }' \
  hosts/codex/agents/fablewright-glm-implementer.toml > "$smuggle/fablewright-glm-implementer.toml"
expect_status 1 'a provider line inside developer_instructions is refused' \
  ./scripts/install-agents.sh --target-dir "$smuggle" --check-role glm-implementer

for position in end after-model; do
  pos_dir=$tmp_root/pos-$position
  ./scripts/install-agents.sh --target-dir "$pos_dir" >/dev/null
  target=$pos_dir/fablewright-glm-implementer.toml
  if [ "$position" = end ]; then
    printf 'model_provider = "zai"\n' >> "$target"
  else
    awk '/^model = / { print; print "model_provider = \"zai\""; next } { print }' \
      hosts/codex/agents/fablewright-glm-implementer.toml > "$target"
  fi
  expect_status 0 "a provider line $position of the instructions block is accepted" \
    ./scripts/install-agents.sh --target-dir "$pos_dir" --check-role glm-implementer
done

expect_output 'provider: zai (lane profile)' 'cast-call reads the provider from the profile' \
  ./scripts/cast-call.sh --lane glm --profile-dir "$prov_dir" --check
expect_output 'provider: other (--provider)' '--provider overrides the profile pin' \
  ./scripts/cast-call.sh --lane glm --profile-dir "$prov_dir" --provider other --check

group 'cast-call: lane resolution'
for lane in luna terra flash glm; do
  expect_status 0 "implementer lane resolves: $lane" ./scripts/cast-call.sh --lane "$lane" --check
done
expect_output 'model=gpt-5.6-luna' 'luna pins gpt-5.6-luna' ./scripts/cast-call.sh --lane luna --check
expect_output 'effort=max' 'luna pins max effort' ./scripts/cast-call.sh --lane luna --check
expect_output 'model=gpt-5.6-terra' 'terra pins gpt-5.6-terra' ./scripts/cast-call.sh --lane terra --check
expect_output 'effort=xhigh' 'terra pins xhigh effort' ./scripts/cast-call.sh --lane terra --check
expect_output 'model=deepseek-v4-flash' 'flash pins deepseek-v4-flash' ./scripts/cast-call.sh --lane flash --check
expect_output 'model=glm-4.6' 'glm implementer pins glm-4.6' ./scripts/cast-call.sh --lane glm --check
expect_output 'sandbox=read-only' 'sol reviewer is read-only' ./scripts/cast-call.sh --lane sol --kind reviewer --check
expect_output 'sandbox=read-only' 'glm reviewer is read-only' ./scripts/cast-call.sh --lane glm --kind reviewer --check
expect_status 64 'a reviewer request never resolves to an implementer' \
  ./scripts/cast-call.sh --lane f --kind reviewer --check
expect_status 64 'an unknown lane is rejected' ./scripts/cast-call.sh --lane nope --check
expect_status 64 'a missing --lane is rejected' ./scripts/cast-call.sh --check
expect_status 64 'an invalid sandbox is rejected' \
  ./scripts/cast-call.sh --lane luna --sandbox nope --check
expect_output 'model_provider=zai' '--provider reaches the command line' \
  ./scripts/cast-call.sh --lane glm --provider zai --dry-run
expect_output '-c model_reasoning_effort=max' 'the pinned effort reaches the command line' \
  ./scripts/cast-call.sh --lane luna --dry-run

group 'cast-call: profile integrity is enforced'
bad_profiles=$tmp_root/bad-profiles
mkdir -p "$bad_profiles"

cat > "$bad_profiles/fablewright-nomodel-implementer.toml" <<'PROFILE'
name = "fablewright_nomodel_implementer"
description = "no model pin"

developer_instructions = """
Do the thing.
"""
PROFILE
expect_status 69 'a profile with no model pin is refused' \
  ./scripts/cast-call.sh --lane nomodel --profile-dir "$bad_profiles" --check

cat > "$bad_profiles/fablewright-noinstr-implementer.toml" <<'PROFILE'
name = "fablewright_noinstr_implementer"
description = "no instructions"
model = "gpt-5.6-luna"
PROFILE
expect_status 69 'a profile with no standing instructions is refused' \
  ./scripts/cast-call.sh --lane noinstr --profile-dir "$bad_profiles" --check

ln -s "$repo_root/hosts/codex/agents/fablewright-luna-implementer.toml" \
  "$bad_profiles/fablewright-linked-implementer.toml"
expect_status 69 'a symlinked lane profile is refused' \
  ./scripts/cast-call.sh --lane linked --profile-dir "$bad_profiles" --check

expect_status 64 'a missing profile directory is rejected' \
  ./scripts/cast-call.sh --lane luna --profile-dir "$tmp_root/does-not-exist" --check

instr=$(awk -v q="$(printf '%s' '"""')" '
  !inblock && index($0, "developer_instructions") && index($0, q) { inblock = 1; next }
  inblock && $0 ~ ("^[[:space:]]*" q "[[:space:]]*$") { exit }
  inblock { print }
' hosts/codex/agents/fablewright-luna-implementer.toml)
case "$instr" in
  *'routine implementation lane'*) ok 'standing instructions are extracted from the profile' ;;
  *) bad 'standing instructions are extracted from the profile' ;;
esac

group 'cast-call: routing verification, end to end with a stub runtime'
stub_root=$tmp_root/stub
mkdir -p "$stub_root/bin"

make_rollout() {
  home=$1; tid=$2; mdl=$3; shift 3
  dir=$home/sessions/2026/01/01
  mkdir -p "$dir"
  f=$dir/rollout-2026-01-01T00-00-00-$tid.jsonl
  printf '{"type":"session_meta","payload":{"id":"%s","parent_thread_id":null,"agent_role":null,"agent_path":null,"model_provider":"openai"}}\n' \
    "$tid" > "$f"
  for eff in "$@"; do
    printf '{"type":"turn_context","payload":{"model":"%s","effort":"%s","cwd":"/repo","sandbox_policy":{"type":"workspace-write"},"permission_profile":{"type":"managed"}}}\n' \
      "$mdl" "$eff" >> "$f"
  done
}

cat > "$stub_root/bin/codex" <<'STUB'
out=''
prev=''
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out=$arg; fi
  prev=$arg
done
cat >/dev/null
printf '{"type":"thread.started","thread_id":"%s"}\n' "$FW_STUB_THREAD"
printf '{"type":"turn.completed"}\n'
[ -n "$out" ] && printf 'STUB IMPLEMENTATION REPORT\n' > "$out"
exit 0
STUB
chmod 0755 "$stub_root/bin/codex"

stub_home=$stub_root/home
good_tid=11111111-1111-1111-1111-111111111111
bad_tid=22222222-2222-2222-2222-222222222222
make_rollout "$stub_home" "$good_tid" gpt-5.6-luna max max max
make_rollout "$stub_home" "$bad_tid"  gpt-5.6-luna low low max

stub_spec=$tmp_root/stub-spec.txt
printf 'OBJECTIVE\nstub\n\nFILES AND OWNERSHIP\nnone\n\nINTERFACES\nnone\n\nCONSTRAINTS\nnone\n\nVERIFICATION\nnone\n' \
  > "$stub_spec"

run_stub() {
  tid=$1; shift
  FW_STUB_THREAD=$tid CODEX_HOME=$stub_home PATH="$stub_root/bin:$PATH" \
    ./scripts/cast-call.sh --lane luna --cwd "$tmp_root" "$@" < "$stub_spec" 2>&1
}

expect_output 'verified' 'a lane that held its pinned effort every turn is verified' \
  run_stub "$good_tid"
expect_output 'effort=max(all 3 turns)' 'the proof states that every turn was checked' \
  run_stub "$good_tid"
expect_status 69 'a lane that dropped below its pinned effort is refused' \
  run_stub "$bad_tid"
expect_output_status 69 'also ran at: low' 'the refusal names the off-pin effort' \
  run_stub "$bad_tid"

unpinned_tid=33333333-3333-3333-3333-333333333333
make_rollout "$stub_home" "$unpinned_tid" glm-4.6 medium
expect_output 'NOT pinned' 'an unpinned field is reported as observed, not as checked' \
  sh -c "FW_STUB_THREAD=$unpinned_tid CODEX_HOME=$stub_home PATH=\"$stub_root/bin:\$PATH\" ./scripts/cast-call.sh --lane glm --cwd '$tmp_root' < '$stub_spec' 2>&1"

victim=$tmp_root/victim.txt
printf 'original\n' > "$victim"
ln -s "$victim" "$tmp_root/report-link.txt"
expect_status 64 '--report refuses a symlink destination' \
  run_stub "$good_tid" --report "$tmp_root/report-link.txt"
if [ "$(cat "$victim")" = "original" ]; then
  ok 'a --report symlink target is left untouched'
else
  bad 'a --report symlink target is left untouched'
fi
expect_output_status 64 'STUB IMPLEMENTATION REPORT' 'an unwritable --report path still prints the result' \
  run_stub "$good_tid" --report "$tmp_root/no-such-dir/x.txt"

group 'ask-wright: a packet may begin with any character'
wright_stub=$tmp_root/wright/bin
mkdir -p "$wright_stub"
cat > "$wright_stub/claude" <<'STUB'
packet=''
prev=''
seen_sep=0
for arg in "$@"; do
  if [ "$seen_sep" = 1 ]; then packet=$arg; break; fi
  [ "$arg" = "--" ] && seen_sep=1
  prev=$arg
done
[ -n "$packet" ] || packet='NO_PACKET_RECEIVED'
printf '{"is_error":false,"terminal_reason":"completed","permission_denials":[],'
printf '"modelUsage":{"claude-fable-5-1":{}},"result":"RECEIVED:%s"}\n' \
  "$(printf '%s' "$packet" | head -1 | tr -d '"\\\\')"
exit 0
STUB
chmod 0755 "$wright_stub/claude"

run_wright() {
  PATH="$wright_stub:$PATH" ./scripts/ask-wright.sh --effort low 2>&1
}
ask_wright_with() {
  [ "$1" = "--" ] && shift
  printf '%s\nOBJECTIVE\nx\n' "$1" | PATH="$wright_stub:$PATH" ./scripts/ask-wright.sh --effort low 2>&1
}
expect_output 'RECEIVED:--- fenced packet' 'a packet opening with --- reaches the wright intact' \
  ask_wright_with -- '--- fenced packet'
expect_output 'RECEIVED:- bullet packet' 'a packet opening with a bullet reaches the wright intact' \
  ask_wright_with -- '- bullet packet'

group 'cast-call: --ephemeral is not reported as success'
expect_status 75 '--ephemeral exits 75, so a caller gating on 0 never sees it as verified' \
  run_stub "$good_tid" --ephemeral
expect_output_status 75 'routing: waived' '--ephemeral says waived rather than verified' \
  run_stub "$good_tid" --ephemeral

group 'installer: target directory resolution'
expect_status 1 'refuses /.' ./scripts/install-agents.sh --target-dir /. --dry-run
expect_status 1 'refuses ///' ./scripts/install-agents.sh --target-dir /// --dry-run
expect_status 1 'refuses /' ./scripts/install-agents.sh --target-dir / --dry-run
link_root=$tmp_root/linkroot
mkdir -p "$link_root/real"
ln -s "$link_root/real" "$link_root/link"
expect_output 'real/agents' 'a symlinked ancestor is canonicalized and reported, not silently followed' \
  ./scripts/install-agents.sh --target-dir "$link_root/link/agents" --dry-run
expect_status 1 'refuses a path containing a .. component' \
  ./scripts/install-agents.sh --target-dir "$tmp_root/a/../b" --dry-run

group 'installer: the closing summary is honest'
honest=$tmp_root/honest
./scripts/install-agents.sh --target-dir "$honest" >/dev/null
expect_output 'exactly' 'an untouched install claims exactness' \
  ./scripts/install-agents.sh --target-dir "$honest"
printf 'model_provider = "zai"\n' >> "$honest/fablewright-glm-implementer.toml"
expect_output 'apart from the provider customizations' 'a customized install does not claim exactness' \
  ./scripts/install-agents.sh --target-dir "$honest"

group 'cast-call: a sandbox override may narrow but never widen'
expect_status 64 'a read-only reviewer cannot be widened to danger-full-access' \
  ./scripts/cast-call.sh --lane sol --kind reviewer --sandbox danger-full-access --check
expect_status 64 'a read-only reviewer cannot be widened to workspace-write' \
  ./scripts/cast-call.sh --lane sol --kind reviewer --sandbox workspace-write --check
expect_output 'sandbox=read-only' 'an implementer may be narrowed to read-only' \
  ./scripts/cast-call.sh --lane luna --sandbox read-only --check
expect_output 'sandbox=read-only' 'a reviewer may be re-stated at its own pin' \
  ./scripts/cast-call.sh --lane sol --kind reviewer --sandbox read-only --check

group 'installer: role arguments cannot split or glob'
expect_status 64 'a glob character is rejected rather than expanded' \
  ./scripts/install-agents.sh --check-role '*' --target-dir "$tmp_root/none"
expect_status 64 'whitespace is rejected rather than split into two roles' \
  ./scripts/install-agents.sh --check-role 'luna-implementer glm-reviewer' --target-dir "$tmp_root/none"
expect_status 64 'a path separator is rejected' \
  ./scripts/install-agents.sh --check-role '../etc' --target-dir "$tmp_root/none"

group 'ask-wright: a broken pattern is not reported as a substitution'
expect_status 64 'an invalid model pattern is a configuration fault, not a substitution' \
  env FABLEWRIGHT_MODEL_PATTERN='[' PATH="$wright_stub:$PATH" ./scripts/ask-wright.sh --check
expect_output_status 64 'configuration fault' 'the message says configuration fault, not substitute wright' \
  env FABLEWRIGHT_MODEL_PATTERN='[' PATH="$wright_stub:$PATH" ./scripts/ask-wright.sh --check
expect_output_status 69 'does not accept a substitute wright' 'a genuine mismatch still accuses substitution' \
  env FABLEWRIGHT_MODEL_PATTERN='^definitely-not-fable' PATH="$wright_stub:$PATH" ./scripts/ask-wright.sh --check

group 'the sidecar provider map is read from the path the docs name'
if grep -q 'hosts/codex/lane-providers.tsv' skills/fablewright/references/providers.md; then
  ok 'providers.md names the real sidecar path'
else
  bad 'providers.md names the real sidecar path'
fi
sidecar_dir=$tmp_root/sidecar
mkdir -p "$sidecar_dir/agents"
cp hosts/codex/agents/fablewright-glm-implementer.toml "$sidecar_dir/agents/"
printf 'glm-implementer\tzai-from-sidecar\n' > "$sidecar_dir/lane-providers.tsv"
expect_output 'provider: zai-from-sidecar (lane-providers.tsv)' \
  'cast-call reads the sidecar one level above the profile directory' \
  ./scripts/cast-call.sh --lane glm --profile-dir "$sidecar_dir/agents" --check

group 'installer: a mid-run failure rolls back'
rb_dir=$tmp_root/rollback
expect_status 1 'an abort partway through the write loop fails' \
  env FABLEWRIGHT_TEST_FAIL_AFTER=3 ./scripts/install-agents.sh --target-dir "$rb_dir"
if [ "$(ls -1 "$rb_dir" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok 'nothing this run created survives the abort'
else
  bad 'nothing this run created survives the abort' "left: $(ls -1 "$rb_dir" | tr '\n' ' ')"
fi
expect_output_status 1 'Rolling back this partial install' 'the rollback is reported, not silent' \
  env FABLEWRIGHT_TEST_FAIL_AFTER=2 ./scripts/install-agents.sh --target-dir "$tmp_root/rollback2"
expect_status 0 'a normal install still succeeds after a rolled-back attempt' \
  ./scripts/install-agents.sh --target-dir "$rb_dir"
expect_status 0 'and the rolled-back-then-installed set is exact' \
  ./scripts/install-agents.sh --target-dir "$rb_dir" --check
expect_status 0 'a re-run over a current install writes nothing, so it cannot roll anything back' \
  env FABLEWRIGHT_TEST_FAIL_AFTER=1 ./scripts/install-agents.sh --target-dir "$rb_dir"
expect_status 0 'the previously installed roles are untouched by it' \
  ./scripts/install-agents.sh --target-dir "$rb_dir" --check

rm -f "$rb_dir/fablewright-terra-implementer.toml"
expect_status 1 'a partial run that adds one role and aborts fails' \
  env FABLEWRIGHT_TEST_FAIL_AFTER=1 ./scripts/install-agents.sh --target-dir "$rb_dir"
if [ ! -e "$rb_dir/fablewright-terra-implementer.toml" ]; then
  ok 'the role this run added is removed'
else
  bad 'the role this run added is removed'
fi
if [ -f "$rb_dir/fablewright-luna-implementer.toml" ] && [ -f "$rb_dir/fablewright-sol-reviewer.toml" ]; then
  ok 'roles installed by an earlier run survive the rollback'
else
  bad 'roles installed by an earlier run survive the rollback'
fi
./scripts/install-agents.sh --target-dir "$rb_dir" >/dev/null

group 'the ensemble independence rule is stated where the wright will read it'
for doc in skills/fablewright/SKILL.md skills/fablewright/references/role-contracts.md \
           skills/fablewright/references/call-sheet.md; do
  if tr '\n' ' ' < "$doc" | tr -s ' ' | grep -q 'one model family\|one family'; then
    ok "states the single-family ensemble rule: ${doc##*/}"
  else
    bad "states the single-family ensemble rule: ${doc##*/}"
  fi
done
if tr '\n' ' ' < skills/fablewright/SKILL.md | tr -s ' ' | grep -q 'independence: partial'; then
  ok 'names the partial-independence escape hatch'
else
  bad 'names the partial-independence escape hatch'
fi

group 'offline paths need no CLI installed'
bare=$tmp_root/bare-path
mkdir -p "$bare"
for tool in sh awk sed grep cmp cat head tail sort uniq tr wc ln mv rm cp ls find mktemp printf shasum dirname basename readlink; do
  tool_path=$(command -v "$tool" 2>/dev/null) && ln -sf "$tool_path" "$bare/$tool"
done
expect_status 0 'cast-call --check works with no codex on PATH' \
  env PATH="$bare" ./scripts/cast-call.sh --lane luna --check
expect_status 0 'cast-call --dry-run works with no codex on PATH' \
  env PATH="$bare" ./scripts/cast-call.sh --lane luna --dry-run
expect_status 64 'cast-call usage errors stay usage errors with no codex on PATH' \
  env PATH="$bare" ./scripts/cast-call.sh --lane nope --check
expect_status 64 'ask-wright usage errors stay usage errors with no claude on PATH' \
  env PATH="$bare" ./scripts/ask-wright.sh --effort turbo --check
expect_status 0 'install-agents --check works with no CLI on PATH' \
  env PATH="$bare" ./scripts/install-agents.sh --target-dir "$codex_dir" --check-role terra

group 'the profile parser is structure-aware'
decoy=$tmp_root/decoy
mkdir -p "$decoy"
{
  printf 'name = "fablewright_decoy_implementer"\n'
  printf 'model = "gpt-5.6-luna" # trailing comment\n\n'
  printf 'developer_instructions = """\n'
  printf 'model = "totally-different-model"\n'
  printf 'model_provider = "attacker-relay"\n'
  printf '"""\n'
} > "$decoy/fablewright-decoy-implementer.toml"
expect_output 'model=gpt-5.6-luna' 'a trailing comment is stripped from the model pin' \
  ./scripts/cast-call.sh --lane decoy --profile-dir "$decoy" --check
decoy_out=$(./scripts/cast-call.sh --lane decoy --profile-dir "$decoy" --check 2>&1 || true)
case "$decoy_out" in
  *totally-different-model*) bad 'a decoy model inside the instructions body is ignored' ;;
  *) ok 'a decoy model inside the instructions body is ignored' ;;
esac
case "$decoy_out" in
  *attacker-relay*) bad 'a decoy provider inside the instructions body is ignored' ;;
  *) ok 'a decoy provider inside the instructions body is ignored' ;;
esac

group 'ask-wright: offline argument handling'
expect_status 64 'an invalid effort is rejected' ./scripts/ask-wright.sh --effort turbo --check
expect_status 64 'an unknown option is rejected' ./scripts/ask-wright.sh --nope
expect_status 64 'an empty packet is rejected' sh -c 'printf "" | ./scripts/ask-wright.sh'

printf '\n%s\n' "-----------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
