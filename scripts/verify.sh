#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$repo_root"

EXPECTED_VERSION=1.0.0

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  if [ -n "${2-}" ]; then printf '       %s\n' "$2"; fi
  return 0
}
group() { printf '\n%s\n' "$1"; }

need_file() { if [ -f "$1" ]; then ok "present: $1"; else bad "present: $1"; fi; }

contains() {
  flat=$(tr '\n' ' ' < "$1" 2>/dev/null | tr -s ' ' | tr '[:upper:]' '[:lower:]')
  needle=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  case "$flat" in
    *"$needle"*) ok "$3" ;;
    *) bad "$3" "missing in $1: $2" ;;
  esac
}

group 'required files'
for f in \
  README.md LICENSE CHANGELOG.md CONTRIBUTING.md SECURITY.md \
  .claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json \
  skills/fablewright/SKILL.md \
  skills/fablewright/agents/openai.yaml \
  skills/fablewright/references/call-sheet.md \
  skills/fablewright/references/role-contracts.md \
  skills/fablewright/references/operations.md \
  skills/fablewright/references/hosts.md \
  skills/fablewright/references/providers.md \
  scripts/ask-wright.sh scripts/cast-call.sh scripts/install-agents.sh \
  scripts/inspect-agent-runtime.sh scripts/verify.sh \
  tests/run-tests.sh \
  hosts/codex/lane-providers.tsv hosts/codex/legacy-digests.txt \
  hosts/claude-code/legacy-digests.txt
do
  need_file "$f"
done

group 'lane profiles'
expected_codex_roles='flash-implementer glm-implementer glm-reviewer luna-implementer sol-reviewer terra-implementer'
actual_codex_roles=$(for f in hosts/codex/agents/fablewright-*.toml; do
  b=${f##*/}; b=${b#fablewright-}; printf '%s ' "${b%.toml}"
done | sed 's/ *$//')
if [ "$actual_codex_roles" = "$(printf '%s' "$expected_codex_roles" | sed 's/ *$//')" ]; then
  ok 'the codex host ships exactly the six expected lane profiles'
else
  bad 'the codex host ships exactly the six expected lane profiles' "got: $actual_codex_roles"
fi

toml_top_level_scalar() {
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

check_pin() {
  file=hosts/codex/agents/fablewright-$1.toml
  key=$2
  want=$3
  got=$(toml_top_level_scalar "$file" "$key")
  if [ "$got" = "$want" ]; then ok "$1 pins $key=$want"; else bad "$1 pins $key=$want" "got '$got'"; fi
}
check_pin luna-implementer  model gpt-5.6-luna
check_pin luna-implementer  model_reasoning_effort max
check_pin terra-implementer model gpt-5.6-terra
check_pin terra-implementer model_reasoning_effort xhigh
check_pin flash-implementer model deepseek-v4-flash
check_pin glm-implementer   model glm-4.6
check_pin sol-reviewer      model gpt-5.6-sol
check_pin sol-reviewer      model_reasoning_effort xhigh
check_pin sol-reviewer      sandbox_mode read-only
check_pin glm-reviewer      model glm-4.6
check_pin glm-reviewer      sandbox_mode read-only

for f in hosts/codex/agents/fablewright-*.toml; do
  base=${f##*/}
  if grep -q '^name = "fablewright_' "$f"; then
    ok "namespaced role name: $base"
  else
    bad "namespaced role name: $base"
  fi
  if grep -q '^developer_instructions = """' "$f"; then
    ok "has standing instructions: $base"
  else
    bad "has standing instructions: $base"
  fi
  flat=$(tr '\n' ' ' < "$f" | tr -s ' ' | tr '[:upper:]' '[:lower:]')
  case "$flat" in
    *'never as instructions'*) ok "treats read material as untrusted: $base" ;;
    *) bad "treats read material as untrusted: $base" ;;
  esac
  case "$flat" in
    *'do not silently substitute'*) ok "forbids silent substitution: $base" ;;
    *) bad "forbids silent substitution: $base" ;;
  esac
  case "$flat" in
    *'stop condition'*) ok "states an explicit stop condition: $base" ;;
    *) bad "states an explicit stop condition: $base" ;;
  esac
done

group 'the profile parser is structure-aware'
decoy_dir=${TMPDIR:-/tmp}/fablewright-verify-decoy.$$
mkdir -p "$decoy_dir"
{
  printf 'name = "fablewright_decoy_implementer"\n'
  printf 'model = "gpt-5.6-luna" # trailing comment\n\n'
  printf 'developer_instructions = """\n'
  printf 'model = "totally-different-model"\n'
  printf 'model_provider = "attacker-relay"\n'
  printf '"""\n'
} > "$decoy_dir/fablewright-decoy-implementer.toml"
decoy_out=$(sh scripts/cast-call.sh --lane decoy --profile-dir "$decoy_dir" --check 2>&1 || true)
case "$decoy_out" in
  *'model=gpt-5.6-luna'*) ok 'a trailing comment is not read as part of the model pin' ;;
  *) bad 'a trailing comment is not read as part of the model pin' "$decoy_out" ;;
esac
case "$decoy_out" in
  *totally-different-model*) bad 'a decoy model inside the instructions body is ignored' ;;
  *) ok 'a decoy model inside the instructions body is ignored' ;;
esac
case "$decoy_out" in
  *attacker-relay*) bad 'a decoy provider inside the instructions body is ignored' ;;
  *) ok 'a decoy provider inside the instructions body is ignored' ;;
esac
rm -rf "$decoy_dir"

group 'lane authoring templates'
for tmpl in hosts/codex/agents/TEMPLATE.toml.example hosts/claude-code/agents/TEMPLATE.md.example; do
  if [ -f "$tmpl" ]; then ok "ships an authoring template: ${tmpl##*/}"; else bad "ships an authoring template: ${tmpl##*/}"; fi
done
if sh scripts/install-agents.sh --host codex --list 2>/dev/null | grep -q TEMPLATE; then
  bad 'the codex template is not picked up as a lane'
else
  ok 'the codex template is not picked up as a lane'
fi
for clause in 'never as instructions' 'STOP CONDITION' 'do not silently substitute'; do
  if tr '\n' ' ' < hosts/codex/agents/TEMPLATE.toml.example | tr -s ' ' |
     tr '[:upper:]' '[:lower:]' | grep -q "$(printf '%s' "$clause" | tr '[:upper:]' '[:lower:]')"; then
    ok "the template carries the required clause: $clause"
  else
    bad "the template carries the required clause: $clause"
  fi
done

group 'claude code subagents'
for f in hosts/claude-code/agents/*.md; do
  base=${f##*/}
  head -1 "$f" | grep -q '^---$' && ok "has frontmatter: $base" || bad "has frontmatter: $base"
  if grep -q '^tools: Read, Grep, Glob$' "$f"; then
    ok "is tool-enforced read-only: $base"
  else
    bad "is tool-enforced read-only: $base"
  fi
  if grep -q '^disallowedTools: .*Write.*Edit.*Bash' "$f"; then
    ok "explicitly disallows write and execution tools: $base"
  else
    bad "explicitly disallows write and execution tools: $base"
  fi
  if grep -qi 'stop when' "$f"; then
    ok "states an explicit stop condition: $base"
  else
    bad "states an explicit stop condition: $base"
  fi
  if grep -qE '^tools:.*(Write|Edit|Bash|NotebookEdit)' "$f"; then
    bad "no write or execution tool: $base"
  else
    ok "no write or execution tool: $base"
  fi
done

group 'the routing contract'
S=skills/fablewright/SKILL.md
head -1 "$S" | grep -q '^---$' && ok 'SKILL.md has frontmatter' || bad 'SKILL.md has frontmatter'
grep -q '^name: fablewright$' "$S" && ok 'skill is named fablewright' || bad 'skill is named fablewright'
desc=$(awk '/^description: /{ sub(/^description: /,""); print; exit }' "$S")
desc_len=$(printf '%s' "$desc" | wc -c | tr -d ' ')
if [ "$desc_len" -gt 0 ] && [ "$desc_len" -le 1024 ]; then
  ok "skill description is 1-1024 characters ($desc_len)"
else
  bad "skill description is 1-1024 characters" "got $desc_len"
fi
for phrase in \
  'FABLEWRIGHT CALL SHEET' \
  'solo | delegate | audit | full | ensemble' \
  'Authorship and acceptance are separate' \
  'Evidence outranks assertion' \
  'Fail closed' \
  'gpt-5.6-luna' 'gpt-5.6-terra' 'deepseek-v4-flash' 'glm-4.6' \
  'sol-reviewer' 'glm-reviewer' 'fablewright-reader' \
  'every cast lane must come from one family' \
  'cross-family' 'same-family'
do
  contains "$S" "$phrase" "contract states: $phrase"
done

group 'reference cross-links resolve'
for md in "$S" skills/fablewright/references/*.md; do
  dir=$(dirname "$md")
  targets=$(grep -oE '\]\(([A-Za-z0-9_./-]+\.md)\)' "$md" 2>/dev/null | sed 's/^](//; s/)$//' | sort -u)
  for t in $targets; do
    if [ -f "$dir/$t" ]; then
      ok "link resolves: ${md##*/} -> $t"
    else
      bad "link resolves: ${md##*/} -> $t"
    fi
  done
done

group 'plugin commands use plugin-root relative paths'
bare_paths=0
for cmd in hosts/claude-code/commands/*.md; do
  offenders=$(grep -nE '`(skills|scripts|hosts)/' "$cmd" 2>/dev/null |
    grep -v 'CLAUDE_PLUGIN_ROOT' || true)
  if [ -n "$offenders" ]; then
    bad "uses a plugin-root relative path: ${cmd##*/}" "$(printf '%s' "$offenders" | head -1)"
    bare_paths=$((bare_paths + 1))
  fi
done
[ "$bare_paths" -eq 0 ] && ok 'every command references repo files via ${CLAUDE_PLUGIN_ROOT}'

group 'every referenced image exists'
missing_images=0
for image in $(grep -oE '!\[[^]]*\]\(([^)]+\.(png|jpg|jpeg|svg|gif))\)' README.md docs/*.md 2>/dev/null |
  sed 's/.*(//; s/)$//' | sort -u); do
  case "$image" in http*) continue ;; esac
  if [ -f "$image" ]; then
    ok "image exists: $image"
  else
    bad "image exists: $image" 'a README referencing a missing image renders a broken icon'
    missing_images=$((missing_images + 1))
  fi
done
for image in docs/images/architecture.png docs/images/proof.png docs/images/routes.png; do
  if grep -Fq "$image" README.md; then
    ok "README uses the diagram: ${image##*/}"
  else
    bad "README uses the diagram: ${image##*/}"
  fi
done

group 'every internal document link resolves'
broken_links=0
link_report=${TMPDIR:-/tmp}/fablewright-links.$$
: > "$link_report"
find . -name '*.md' -not -path './.git/*' -print 2>/dev/null | while IFS= read -r md; do
  dir=$(dirname "$md")
  grep -oE '\]\(([A-Za-z0-9_./-]+\.(md|toml|sh|json|tsv|yml|yaml))\)' "$md" 2>/dev/null |
    sed 's/^](//; s/)$//' |
    while IFS= read -r target; do
      case "$target" in http*|'') continue ;; esac
      if [ ! -e "$dir/$target" ] && [ ! -e "$target" ]; then
        printf '%s -> %s\n' "${md#./}" "$target" >> "$link_report"
      fi
    done
done
if [ -s "$link_report" ]; then
  while IFS= read -r entry; do
    bad "link resolves: $entry"
    broken_links=$((broken_links + 1))
  done < "$link_report"
else
  ok 'every internal document link resolves'
fi
rm -f "$link_report"

group 'every documented command still runs'
doc_tmp=${TMPDIR:-/tmp}/fablewright-doccheck.$$
run_documented() {
  label=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "documented command runs: $label"; else bad "documented command runs: $label"; fi
}
run_documented 'install-agents.sh --host codex --list' \
  sh scripts/install-agents.sh --host codex --list
run_documented 'install-agents.sh --host codex --dry-run' \
  sh scripts/install-agents.sh --host codex --dry-run --target-dir "$doc_tmp/codex"
run_documented 'install-agents.sh --host claude-code --dry-run' \
  sh scripts/install-agents.sh --host claude-code --dry-run --target-dir "$doc_tmp/claude"
run_documented 'cast-call.sh --lane glm --check' \
  sh scripts/cast-call.sh --lane glm --check
run_documented 'cast-call.sh --lane glm --dry-run' \
  sh scripts/cast-call.sh --lane glm --dry-run
run_documented 'ask-wright.sh --help' sh scripts/ask-wright.sh --help
run_documented 'inspect-agent-runtime.sh --help' sh scripts/inspect-agent-runtime.sh --help
rm -rf "$doc_tmp"

group 'manifests'
for j in .claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json; do
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open('$j'))" 2>/dev/null &&
      ok "valid JSON: $j" || bad "valid JSON: $j"
  fi
done
for j in .claude-plugin/plugin.json .codex-plugin/plugin.json; do
  if grep -Fq "\"version\": \"$EXPECTED_VERSION\"" "$j"; then
    ok "version is $EXPECTED_VERSION: $j"
  else
    bad "version is $EXPECTED_VERSION: $j"
  fi
done
for s in scripts/install-agents.sh scripts/cast-call.sh scripts/ask-wright.sh \
         scripts/inspect-agent-runtime.sh scripts/bump-version.sh scripts/verify.sh; do
  if grep -Fq "VERSION=$EXPECTED_VERSION" "$s"; then
    ok "version is $EXPECTED_VERSION: $s"
  else
    bad "version is $EXPECTED_VERSION: $s"
  fi
done
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' && ok 'every lane profile is valid TOML' || bad 'every lane profile is valid TOML'
import glob, sys
try:
    import tomllib
except ImportError:
    sys.exit(0)
for f in glob.glob('hosts/codex/agents/*.toml'):
    with open(f, 'rb') as fh:
        tomllib.load(fh)
PY
fi
if command -v claude >/dev/null 2>&1; then
  if claude plugin validate . --strict >/dev/null 2>&1; then
    ok 'claude plugin validate --strict passes'
  else
    bad 'claude plugin validate --strict passes'
  fi
else
  printf '  skip claude plugin validate (claude not on PATH)\n'
fi

group 'manifest and frontmatter structure'
if command -v python3 >/dev/null 2>&1; then
  structure_report=${TMPDIR:-/tmp}/fablewright-structure.$$
  set +e
  python3 - > "$structure_report" 2>&1 <<'PYEOF'
import json, os, re, sys

problems = []

def check(condition, message):
    if not condition:
        problems.append(message)

for path in ('.claude-plugin/plugin.json', '.codex-plugin/plugin.json'):
    with open(path) as fh:
        d = json.load(fh)
    check(isinstance(d.get('name'), str) and d['name'], f'{path}: name must be a non-empty string')
    check(re.match(r'^[a-z0-9][a-z0-9-]*$', d.get('name', '')), f'{path}: name must be kebab-case')
    check(re.match(r'^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$', d.get('version', '')),
          f'{path}: version must be semver')
    check(isinstance(d.get('description'), str) and d['description'],
          f'{path}: description must be a non-empty string')
    kw = d.get('keywords')
    check(isinstance(kw, list) and all(isinstance(k, str) and k for k in kw),
          f'{path}: keywords must be a list of non-empty strings')
    author = d.get('author')
    check(isinstance(author, dict) and isinstance(author.get('name'), str),
          f'{path}: author must be an object with a name')

with open('.claude-plugin/plugin.json') as fh:
    cc = json.load(fh)
agents = cc.get('agents')
check(isinstance(agents, list) and agents, '.claude-plugin/plugin.json: agents must be a non-empty list')
for a in agents or []:
    check(isinstance(a, str) and a.startswith('./') and a.endswith('.md'),
          f'.claude-plugin/plugin.json: agent path must start with ./ and end with .md: {a}')
    check(os.path.isfile(a), f'.claude-plugin/plugin.json: agent path does not exist: {a}')
for key in ('skills', 'commands'):
    val = cc.get(key)
    if val is not None:
        check(isinstance(val, str) and val.startswith('./'), f'.claude-plugin/plugin.json: {key} must start with ./')
        check(os.path.isdir(val), f'.claude-plugin/plugin.json: {key} directory does not exist: {val}')

with open('.claude-plugin/marketplace.json') as fh:
    mk = json.load(fh)
check(isinstance(mk.get('plugins'), list) and mk['plugins'],
      'marketplace.json: plugins must be a non-empty list')
for entry in mk.get('plugins', []):
    src = entry.get('source')
    check(isinstance(src, str) and src, 'marketplace.json: every plugin needs a source')
    check(os.path.isdir(src), f'marketplace.json: source does not resolve to a directory: {src}')
    check(os.path.isfile(os.path.join(src, '.claude-plugin', 'plugin.json')),
          f'marketplace.json: source has no .claude-plugin/plugin.json: {src}')

fm_required = {
    'skills/fablewright/SKILL.md': ('name', 'description'),
}
for d, keys in (('hosts/claude-code/agents', ('name', 'description')),
                ('hosts/claude-code/commands', ('description',))):
    for f in sorted(os.listdir(d)):
        if f.endswith('.md') and not f.endswith('.example'):
            fm_required[os.path.join(d, f)] = keys

for path, keys in fm_required.items():
    text = open(path).read()
    check(text.startswith('---\n'), f'{path}: must open with a --- frontmatter fence')
    end = text.find('\n---\n', 3)
    check(end != -1, f'{path}: frontmatter fence is not closed')
    if end == -1:
        continue
    block = text[4:end]
    found = {}
    for line in block.split('\n'):
        if not line or line.startswith((' ', '\t', '#')):
            continue
        if ':' not in line:
            problems.append(f'{path}: frontmatter line is not key: value -> {line[:40]}')
            continue
        k, v = line.split(':', 1)
        found[k.strip()] = v.strip()
    for k in keys:
        check(k in found and found[k], f'{path}: frontmatter is missing {k}')
    if 'description' in found:
        check(len(found['description']) <= 1024, f'{path}: description exceeds 1024 characters')

if problems:
    for p in problems:
        print(p)
    sys.exit(1)
PYEOF
  structure_status=$?
  set -e
  if [ "$structure_status" -eq 0 ]; then
    ok 'manifests and frontmatter are structurally valid'
  else
    bad 'manifests and frontmatter are structurally valid' "$(head -3 "$structure_report")"
  fi
  rm -f "$structure_report"
else
  printf '  skip manifest structure check (python3 not on PATH)\n'
fi

group 'hygiene'
if grep -rInE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-(ant-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}' \
    --exclude-dir=.git --exclude=verify.sh . >/dev/null 2>&1; then
  bad 'no credential-shaped string in the repository'
else
  ok 'no credential-shaped string in the repository'
fi
if grep -rIn -- 'Co-Authored-By\|Co-authored-by\|Generated with \[Claude Code\]' \
    --exclude-dir=.git --exclude=verify.sh . >/dev/null 2>&1; then
  bad 'no tool attribution anywhere in the repository'
else
  ok 'no tool attribution anywhere in the repository'
fi
placeholders=$(grep -rInE '\b(TODO|FIXME|HACK)\b|rest of (the )?code|implement (this|here)' \
  --exclude-dir=.git --exclude=verify.sh \
  --include='*.sh' --include='*.md' --include='*.toml' --include='*.json' . 2>/dev/null |
  grep -v 'mktemp' | grep -v '^\./scripts/verify\.sh:' || true)
if [ -n "$placeholders" ]; then
  bad 'no placeholder markers in shipped files' "$(printf '%s' "$placeholders" | head -3)"
else
  ok 'no placeholder markers in shipped files'
fi

group 'provider guidance is current'
if grep -q 'wire_api = "chat"' skills/fablewright/references/providers.md &&
   ! grep -q 'no longer supported' skills/fablewright/references/providers.md; then
  bad 'providers.md does not recommend a removed wire_api value'
else
  ok 'providers.md does not recommend a removed wire_api value'
fi
if grep -q 'wire_api = "responses"' skills/fablewright/references/providers.md; then
  ok 'providers.md shows the accepted wire_api value'
else
  bad 'providers.md shows the accepted wire_api value'
fi

group 'provider pin guidance is current'
if grep -rq 'cannot pin a provider' skills/ hosts/ README.md 2>/dev/null; then
  bad 'no document repeats the retracted "cannot pin a provider" claim'
else
  ok 'no document repeats the retracted "cannot pin a provider" claim'
fi
if grep -q 'customized' scripts/install-agents.sh; then
  ok 'the installer implements the CUSTOMIZED provider state'
else
  bad 'the installer implements the CUSTOMIZED provider state'
fi

group 'documented counts match reality'
suite_count=$(sh tests/run-tests.sh 2>/dev/null | awk '/^passed: /{ print $2; exit }')
if [ -n "$suite_count" ]; then
  if grep -q "$suite_count offline cases" README.md && grep -q "$suite_count offline cases" CHANGELOG.md; then
    ok "README and CHANGELOG state the real case count ($suite_count)"
  else
    bad "README and CHANGELOG state the real case count" "suite reports $suite_count"
  fi
else
  bad 'could not read the case count from the suite'
fi

group 'behavioural test suite'
if sh tests/run-tests.sh >/dev/null 2>&1; then
  ok 'tests/run-tests.sh passes'
else
  bad 'tests/run-tests.sh passes' 'run it directly to see which case failed'
fi

printf '\n%s\n' "========================================="
printf 'verify %s: passed %s, failed %s\n' "$EXPECTED_VERSION" "$pass" "$fail"
[ "$fail" -eq 0 ] || { printf 'VERIFY FAILED\n'; exit 1; }
printf 'VERIFY PASSED\n'
