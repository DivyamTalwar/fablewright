# Operations

Install, preflight, routing evidence, isolation, and maintainer procedure. Routing
rules are in [call-sheet.md](call-sheet.md), prompt contracts in
[role-contracts.md](role-contracts.md), host differences in [hosts.md](hosts.md),
provider setup in [providers.md](providers.md).

## Lane profiles are the source of truth

| role id | model | effort | sandbox | used for |
|---|---|---|---|---|
| `luna-implementer` | gpt-5.6-luna | max | workspace-write | routine bounded implementation |
| `terra-implementer` | gpt-5.6-terra | xhigh | workspace-write | judgment-heavy or high-risk implementation |
| `flash-implementer` | deepseek-v4-flash | provider default | workspace-write | high-throughput mechanical transformation |
| `glm-implementer` | glm-4.6 | provider default | workspace-write | independent cross-family implementation |
| `sol-reviewer` | gpt-5.6-sol | xhigh | read-only | fresh review of non-GPT-authored work |
| `glm-reviewer` | glm-4.6 | provider default | read-only | fresh cross-family review of GPT-authored work |

Both hosts read the same profiles. Codex spawns them natively by `agent_type`;
`cast-call.sh` parses the same file for its model, effort, sandbox, and standing
instructions. There is one pin per lane and one place it is written.

Never attach per-spawn model or reasoning overrides. A lane that needs a different pin
is a different lane.

## Install

Installation is deliberate and separate from plugin installation, because installing a
plugin registers skills, not user-owned agent profiles.

~~~sh
sh scripts/install-agents.sh --host codex --dry-run
sh scripts/install-agents.sh --host codex
sh scripts/install-agents.sh --host codex --check

sh scripts/install-agents.sh --host claude-code --dry-run
sh scripts/install-agents.sh --host claude-code
~~~

`--list` prints the role ids a host ships. `--target-dir` installs somewhere else,
which is how the test suite exercises the installer without touching a real home
directory.

The installer is all-or-nothing and refuses rather than overwrites:

- A destination that is a symlink or not a regular file is `unsafe` and is never
  written or followed.
- A destination that differs from the shipped profile and is not a known-legacy digest
  is a `conflict`. Remove it deliberately or keep your edit; the installer will not
  choose for you.
- If any role fails preflight, **nothing** is written, including the roles that passed.
- State is re-checked immediately before each write, so a file that changes between
  preflight and mutation aborts instead of being clobbered.
- After installing, every destination is re-compared byte for byte.

`hosts/<host>/agents/legacy-digests.txt` lists `role<TAB>sha256` pairs for profiles a
future version may migrate in place. It is empty in 1.0.0.

## Preflight

Confirm the wright, then preflight only the lanes the posted call sheet calls. Cache a
passing check for the current task only; never carry it across tasks, an install, or a
configuration change.

~~~sh
scripts/ask-wright.sh --check                     # wright reachable and proven Fable
scripts/install-agents.sh --host codex --check-role luna   # one lane's profile is exact
scripts/cast-call.sh --lane luna --check          # the pin the lane will actually use
~~~

`--check-role` accepts a full role id or an unambiguous prefix. `glm` is ambiguous
across `glm-implementer` and `glm-reviewer`, so it fails and asks you to be exact —
that is the intended behaviour, not a defect.

`cast-call.sh --check` validates the pin, not the provider. Only a run proves a provider
can serve a model, and `cast-call.sh` reports plainly when it cannot.

## Routing evidence

Public spawn and details metadata is authoritative. Use the local inspector only for
fields the host did not expose.

~~~sh
scripts/inspect-agent-runtime.sh <thread-id>
scripts/inspect-agent-runtime.sh --require-role fablewright_luna_implementer <thread-id>
scripts/inspect-agent-runtime.sh --sessions-dir /abs/path <thread-id>
~~~

It matches exactly one rollout filename, reads only that file, and emits only
allowlisted fields: `thread_id`, `parent_thread_id`, `agent_role`, `agent_path`,
`model_provider`, `model`, `effort`, `efforts`, `sandbox_policy_type`,
`permission_profile_type`, `cwd`, `turns`. It never prints prompts, messages,
environment variables, tokens, configuration, or rollout payloads.

Behaviour worth knowing, all observed against real rollout files:

- A rollout embeds **both** the subagent's `session_meta` and its parent's. The
  inspector selects by thread id rather than assuming a single record.
- `agent_role` is `null` for a top-level thread such as one started by `codex exec`. A
  null role is reported, not refused. Use `--require-role` to assert a named custom
  agent.
- `effort` legitimately varies per turn. `effort` reports the most recent turn and
  `efforts` lists every distinct value. **`model` must not vary**: a thread that changed
  model mid-flight has unverifiable routing and is refused.
- `sandbox_policy` and `permission_profile` may be an object with a `type` or a bare
  string. Both are handled.

`cast-call.sh` runs this automatically and refuses to return a worker's report when the
observed routing does not match the pin it was asked for. What it compares, exactly:

- **model** and **sandbox**: always.
- **effort**: only when the lane pins one, and then against **every turn**, not the last.
  A lane that drops to a lower effort partway through is refused and the refusal names
  the off-pin value.
- **provider**: only when a provider is pinned or supplied.

A field with no pin to compare against is reported separately as observed-but-not-checked
and never appears inside the `verified [...]` bracket. Exit 0 means verified; a run
whose proof was waived with `--ephemeral` exits 75 instead, so an orchestrator gating on
the exit status cannot confuse the two. The proof says what it did, not
what you would like it to have done:

~~~text
routing: verified [model=gpt-5.6-luna sandbox=read-only effort=max(all 2 turns)];
         observed but NOT pinned, so NOT checked: provider=openai; thread=<uuid>
~~~

Routing can only be checked after the lane has run, because the evidence does not exist
before then. A refused report is therefore not a rollback: a lane that ran with
`workspace-write` may already have changed the tree. `cast-call.sh` says so explicitly
when it refuses, and the wright must inspect the working tree before deciding what to
keep. Run lanes with `--sandbox read-only` whenever the work does not need to write.

## Lane profiles are parsed as TOML, not grepped

The profile parser tracks multiline-string state, stops at the first `[table]` header,
and strips trailing comments. This is a security property, not tidiness: a line such as

~~~text
model_provider = "attacker-relay"
~~~

placed inside a `developer_instructions = """ ... """` body is not a TOML key, and a
naive line grep would adopt it as a genuine pin and silently redirect the lane. The same
parser backs `verify.sh`, so the verifier cannot be fooled by a decoy either.

## The wright is proven, not assumed

`ask-wright.sh` reads the structured result of its Claude Code call and requires all of:
exit status 0, `is_error` false, `terminal_reason` `completed`, no permission denials,
exactly one responding model, and that model matching `^claude-fable-`. Pin a different
model and it refuses rather than relabelling another model's output as the wright.

Override the required pattern with `FABLEWRIGHT_MODEL_PATTERN` only deliberately, and
say so when you do.

## Isolation

Use **observed** isolation, never requested isolation.

- On the Claude Code host, `fablewright-reader` declares `tools: Read, Grep, Glob`. It
  has no write, edit, or execution tool, so read-only is enforced by construction and
  there is no host policy that can broaden it.
- On the Codex host, the reviewer profile *requests* `sandbox_mode = "read-only"`.
  Capture the observed `sandbox_policy_type`. If it is `read-only`, isolation is
  enforced. If the host broadened it, continue only when hard isolation is not required,
  the prompt forbids edits, and you capture exact before-and-after repository state -
  and report the broader policy as residual risk.
- If isolation is unobservable, hard isolation is required, or any mutation occurred,
  stop the lane. Do not repair the mutation under that verdict and do not claim
  enforced read-only.

## Acceptance

The wright owns architecture, complete diff inspection, verification reruns, correction
and escalation decisions, and acceptance. Worker claims never replace direct inspection.
A reader never fixes its own findings, and any fix invalidates the prior verdict.

## Maintainer verification

~~~sh
sh scripts/verify.sh
~~~

It checks manifests, profile exactness, contract wording, shell syntax, JSON and TOML
validity, installer safety behaviour against fixtures, and the absence of
credential-shaped strings. Run it before every release.
