# A real run

Everything on this page is copied from actual output, not written to look plausible.
Where a line was long it has been wrapped; nothing else has been edited.

## 1. Prove the wright before trusting it

```
$ scripts/ask-wright.sh --check
CHECK PASSED: wright reachable and proven as claude-fable-5-1 at effort low.
```

`--check` sends no packet and prints no plan. It passes only when the structured result
shows exit 0, `is_error: false`, `terminal_reason: completed`, no permission denials,
and exactly one responding model whose id matches `^claude-fable-`.

Ask for the wright but pin a different model, and it refuses rather than relabelling
another model's output:

```
$ scripts/ask-wright.sh --model opus --check
ERROR: the pin 'opus' was served by 'claude-opus-5', which does not match
       ^claude-fable-. FABLEWRIGHT does not accept a substitute wright.
$ echo $?
69
```

## 2. Send the wright a packet, get a call sheet

The packet described a rate-limiting task on an Express service, and listed a lane menu
in which `flash` and `glm` were explicitly marked *not callable* because no provider was
configured.

```
$ scripts/ask-wright.sh --effort high < packet.txt

FABLEWRIGHT — the wright speaks (claude-fable-5-1, effort high):

FABLEWRIGHT CALL SHEET
route: full
cast: terra
reader: fablewright_sol_reviewer
independence: same-family
risk: Global middleware on the public API touches every request across 14 route
      modules; correctness depends on ordering relative to auth (per-key limits must
      only apply to a *validated* key, or a spoofed header buys 10x quota), atomic
      Redis counting, and keeping existing route tests green without a live Redis.
      Wide blast radius plus a security-boundary judgment warrants terra over luna and
      an independent read-only review. Only gpt-5.6 family lanes are callable
      (flash/glm have no provider), so author and reader share a family — recorded as
      residual risk, not silently downgraded.
```

Three things worth noticing, none of which were prompted for by name:

- It chose `terra` over `luna` and said why: a security boundary and a wide blast radius.
- It found a real vulnerability in the *requirements* — that per-key limits applied
  before auth validation let a spoofed header buy ten times the quota.
- It recorded `same-family` honestly, because the only cross-family reader was the
  unconfigured `glm` lane. It did not quietly drop the reader or pretend to independence
  it did not have.

The wright then emitted a task graph whose first node was read-only root discovery, and
a complete five-part specification for the `terra` node with exclusive file ownership
naming `src/middleware/rateLimit.ts`, its test file, and *the mount lines only* in
`src/server.ts`.

### A defect this surfaced

An earlier version of the wright prompt named the five routes but never defined them,
and it posted `route: audit` **with** a cast lane — which the contract forbids, since
`audit` means the wright implements. Adding explicit route semantics to the prompt fixed
it, and the run above is the result. The contract is only as good as the definition the
model is actually given.

## 3. Dispatch a lane and prove how it ran

```
$ scripts/cast-call.sh --lane luna --cwd "$W" --sandbox read-only < spec.txt
FABLEWRIGHT CAST REPORT — lane luna (fablewright_luna_implementer)
routing: verified [model=gpt-5.6-luna sandbox=read-only effort=max(all 1 turns)];
         observed but NOT pinned, so NOT checked: provider=openai;
         thread=01a065f7-6ae0-7982-9287-4a8e1bb868fe

IMPLEMENTATION REPORT

- Files changed: none.
- Verification command: `cat note.txt`
- Exit code: `0`
- Actual output: `hello`
- Result: PASS.
```

The `routing:` line is not a label. It was read back out of the runtime's own session
record after the run finished, and compared field by field against the lane profile.

## 4. An unconfigured lane fails closed

`glm-4.6` has no provider on this machine. FABLEWRIGHT does not fall back to a lane that
does work:

```
$ scripts/cast-call.sh --lane glm --cwd "$W" --sandbox read-only < spec.txt
ERROR: the glm lane failed (codex exited 1).
  pinned: model=glm-4.6 effort=provider-default provider=host default sandbox=read-only
  thread_id: 01a065f4-f7c6-7a90-977e-b72b8deccfc8
  cause: the runtime printed no diagnostic beyond unrelated MCP transport errors.
  full stderr: /var/folders/.../fablewright-cast-87185-stderr.log
  This lane is stopped. FABLEWRIGHT does not re-route stopped work to another lane.
$ echo $?
70
```

## 5. The installer refuses rather than overwrites

```
$ printf '\n# hand edited\n' >> "$A/fablewright-luna-implementer.toml"

$ scripts/install-agents.sh --target-dir "$A" --check
ERROR: luna-implementer is conflict, not the current exact profile:
       .../fablewright-luna-implementer.toml

$ scripts/install-agents.sh --target-dir "$A"
ERROR: luna-implementer destination is conflict and will not be replaced:
       .../fablewright-luna-implementer.toml
UNCHANGED: no file was modified during the refusal
```

The last line is a checksum of the whole directory taken before and after the refused
install. One bad role blocks the entire install, including the five roles that passed.

A symlinked destination is neither followed nor replaced:

```
$ ln -s /etc/hosts "$A/fablewright-sol-reviewer.toml"
$ scripts/install-agents.sh --target-dir "$A"
ERROR: sol-reviewer destination is unsafe and will not be replaced: ...
$ readlink "$A/fablewright-sol-reviewer.toml"
/etc/hosts
SYMLINK INTACT: not followed, not overwritten
```

## 6. Routing evidence, from a real rollout

```
$ scripts/inspect-agent-runtime.sh 01a06551-e596-7ee1-b0f8-f37f61d25a2d
{"thread_id":"01a06551-...","parent_thread_id":"01a06540-...",
 "agent_role":"explorer","agent_path":"/root/oss_index_benchmark",
 "model_provider":"openai","model":"gpt-5.6-sol","effort":"xhigh",
 "efforts":["ultra","xhigh"],"sandbox_policy_type":"danger-full-access",
 "permission_profile_type":"disabled","cwd":"...","turns":3}
```

This file exercises three things a naive parser gets wrong, all of which are real:

1. It contains **two** `session_meta` records — the subagent's and its parent's — so the
   right one must be selected by thread id rather than assumed to be the only one.
2. `effort` differs between turns (`ultra` and `xhigh`), so requiring a single effort
   would reject a perfectly valid thread. `model` is the field that must not vary.
3. `agent_role` is `null` for a top-level thread, which is legitimate and is reported
   rather than refused.

## 7. Two documentation claims that turned out to be false

Both were caught by probing the shipped binary rather than trusting published schemas,
and both had already been written into these docs before the probe corrected them.

**`wire_api` accepts exactly one value.** The schema's `WireApi` is a `oneOf` with the
single variant `responses`, and the binary enforces it:

```
$ CODEX_HOME=$probe codex exec --strict-config --skip-git-repo-check -C /tmp "hi"
config.toml:5:12: `wire_api = "chat"` is no longer supported.
                  How to fix: set `wire_api = "responses"` in your provider config.
config.toml:5:12: unknown variant `openai`, expected `responses`
```

`codex doctor` accepts any string here, including nonsense — only `--strict-config`
rejects it. The practical consequence is significant: a third-party endpoint that speaks
only chat-completions cannot serve a Codex lane on 0.153.0.

An earlier draft of `providers.md` claimed the published schema still advertised three
values and told the reader to distrust it. That was wrong — schema and binary agree. It
is recorded here because a document arguing for verification should not itself assert an
unverified conflict.

**A lane profile *can* pin a provider.** The earlier draft of `providers.md` stated the
opposite and built a sidecar file around it. A fail-closed schema probe — write a
candidate key into a throwaway `$CODEX_HOME/agents/probe.toml`, run `codex doctor --json`,
look for `unknown field` — showed otherwise:

```
model_provider           accepted        cwd         REJECTED (unknown field `cwd`)
model_reasoning_effort   accepted        provider    REJECTED (unknown field `provider`)
sandbox_mode             accepted        <nonsense>  REJECTED
developer_instructions   accepted
approval_policy          accepted
tools                    accepted
```

The rejected column is the positive control: without it, "accepted" would only mean the
probe was blind. The provider pin now lives in the lane profile beside the model pin, and
the installer treats exactly one appended `model_provider` line as a supported
customization:

```
$ sh scripts/install-agents.sh --host codex --check
  CUSTOMIZED: glm-implementer pins model_provider="zai"; otherwise byte-exact.
CHECK PASSED: all codex roles match ..., apart from the provider customizations listed above
```

Add a second `model_provider` line, or change anything else, and it is a conflict again.

## 8. The offline gates

```
$ sh tests/run-tests.sh
passed: 143   failed: 0
ALL TESTS PASSED

$ sh scripts/verify.sh
verify 1.0.0: passed 149, failed 0
VERIFY PASSED
```

Both call no model and write nothing outside a temporary directory. The test suite uses
synthetic session fixtures under `tests/fixtures/`, plus a stub runtime that lets the
whole routing-verification path — including a lane that drops below its pinned effort —
be exercised without spending a token.

Neither gate needs the Codex CLI or the Claude Code CLI installed. That is checked, not
assumed: CI asserts both are absent before running, and the counts above are identical
on a runner with neither present (`verify.sh` reports one fewer check there, because it
skips `claude plugin validate` rather than pretending to have run it).
