# Host adapters

FABLEWRIGHT runs the same contract on two hosts. What changes is where the wright
lives and how a cast lane is reached. What never changes is the three laws, the call
sheet, the specification packet, and the refusal to accept an unproven route.

| | Claude Code host | Codex host |
|---|---|---|
| wright | the session model, native | remote, via `scripts/ask-wright.sh` |
| cast lanes | `scripts/cast-call.sh` -> `codex exec` | native custom agents, or `cast-call.sh` |
| reader | native subagent, tool-enforced read-only | custom agent requesting a read-only sandbox |
| routing proof | `modelUsage` in the wright result; rollout inspection for cast lanes | rollout inspection for every lane |

## Claude Code host

The wright is the session. Confirm the session model is Fable 5.1 before the first
route declaration; a skill cannot change it, so if it is not Fable, say so and stop.

Install:

~~~sh
/plugin marketplace add <owner>/fablewright
/plugin install fablewright@fablewright
~~~

Or, for the subagents alone without the plugin:

~~~sh
sh scripts/install-agents.sh --host claude-code --check   # inspect first
sh scripts/install-agents.sh --host claude-code
~~~

**The reader is enforced, not merely requested.** `fablewright-reader` is declared with
`tools: Read, Grep, Glob` and no write, edit, or execution tool. It is structurally
incapable of modifying the repository, so its verdict cannot be contaminated by its own
fixes. This is stronger than a requested sandbox: there is no host policy to broaden.

**The reader is cross-family by construction here.** It runs in the Claude family while
every cast lane is GPT, DeepSeek, or GLM. The one same-family case is a `solo` change
the Fable wright wrote itself and then had read - context-clean, not independent.
Record it as `same-family` and carry it as residual risk.

`fablewright-scout` exists for the same reason the reader does: the wright's context is
the scarce resource. Send it bounded questions and get back cited answers instead of
file dumps.

Reaching a cast lane requires the Codex CLI on PATH, because Claude Code subagents run
Claude models. Dispatch with:

~~~sh
scripts/cast-call.sh --lane luna --cwd "$PWD" < spec.txt
~~~

It composes the lane's pinned instructions with your specification, runs `codex exec`,
then proves what actually ran. It refuses to hand back the report if the observed model
or sandbox differs from the pin, if a pinned effort was not held on every turn, or if a
named provider did not serve the request. Fields with no pin are reported as observed
rather than described as verified.

## Codex host

The wright is remote. Reach it with one hermetic call:

~~~sh
printf '%s' "$PACKET" | scripts/ask-wright.sh --effort xhigh
~~~

The helper pins the model, reads the structured result, and checks the response was
actually served by a Fable model before returning anything. Pin something else and it
refuses rather than relabelling another model's output as the wright. Preflight it with
`scripts/ask-wright.sh --check`, which sends no packet and prints no plan.

Install the lane profiles - plugin installation registers skills, not user-owned agent
profiles, so this step is separate and deliberate:

~~~sh
sh scripts/install-agents.sh --host codex --dry-run   # see exactly what would change
sh scripts/install-agents.sh --host codex
sh scripts/install-agents.sh --host codex --check
~~~

Spawn a native lane with a fresh context and no per-spawn overrides, because the profile
already pins model and effort:

~~~text
agent_type: fablewright_luna_implementer
fork_turns: none
~~~

Substitute `fablewright_terra_implementer`, `fablewright_flash_implementer`,
`fablewright_glm_implementer`, `fablewright_sol_reviewer`, or
`fablewright_glm_reviewer` as the posted call sheet requires.

**Independence needs care on this host.** A `gpt-5.6-sol` reader reading a
`gpt-5.6-luna` or `gpt-5.6-terra` change set is same-family. When the GLM lane is
configured, `fablewright_glm_reviewer` gives genuine cross-family review of GPT-authored
work, and `fablewright_sol_reviewer` gives it of GLM-authored work. Choose the reader
against the author, and record what you got.

## Lanes that need a provider

`luna`, `terra`, and `sol` resolve against the host's default OpenAI provider.
`flash` (`deepseek-v4-flash`) and `glm` (`glm-4.6`) do not: they need a provider that
speaks the OpenAI Responses API, configured on the host and pinned with one
`model_provider` line in the lane profile. Until one is, those lanes are
**unavailable**, which is a blocker to report on the call sheet - never a reason to hand
their work to a lane that happened to answer.

See [providers.md](providers.md) for the configuration, and verify a lane before
relying on it:

~~~sh
scripts/cast-call.sh --lane glm --check   # validates the pin
scripts/cast-call.sh --lane glm --dry-run # shows the exact command
~~~

`--check` proves the profile pins what you think it pins. Only a real run proves the
provider can serve it, and `cast-call.sh` will tell you plainly when it cannot.
