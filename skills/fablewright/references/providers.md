# Providers

Verified against the Codex config schema at
`https://learn.chatgpt.com/docs/config-schema.json` and the local Codex CLI.

## Where a provider can be pinned

`model_provider` is accepted in three places, verified against Codex CLI 0.153.0:

| place | scope | how FABLEWRIGHT uses it |
|---|---|---|
| a lane profile in `$CODEX_HOME/agents/*.toml` | that lane only | the preferred pin - one lane, one file |
| `[profiles.<name>]` in `config.toml` | that profile only | supported, but splits the pin across two files |
| top level of `config.toml` | every model on the machine | avoid; it re-points your default lanes too |

The lane profile is the right home: it keeps the model, the effort, the sandbox, the
standing instructions, and the provider in a single file that both hosts read.

Verified by schema probe against the shipped binary — write a candidate key into a
throwaway `$CODEX_HOME/agents/probe.toml` and run `codex doctor --json`, which prints
`unknown field \`x\`` for a rejected key and stays silent for an accepted one:

~~~text
model_provider          accepted        cwd         REJECTED (unknown field `cwd`)
model_reasoning_effort  accepted        provider    REJECTED (unknown field `provider`)
sandbox_mode            accepted        <nonsense>  REJECTED
developer_instructions  accepted
approval_policy         accepted
tools                   accepted
~~~

The rejected column is the positive control: the probe genuinely discriminates.

Note that the `[agents.<role>]` block **inside** `config.toml` is a different thing and
carries only `config_file`, `description`, and `nickname_candidates`. Do not confuse it
with a lane profile file.

## Configure a provider

Add an OpenAI-compatible provider to your Codex `config.toml`. FABLEWRIGHT never edits
this file for you.

~~~toml
[model_providers.opencode-go]
name = "OpenCode Go"
base_url = "https://<your-endpoint>/v1"
env_key = "OPENCODE_GO_API_KEY"
wire_api = "responses"

[model_providers.zai]
name = "Z.ai"
base_url = "https://<your-endpoint>/v1"
env_key = "ZAI_API_KEY"
wire_api = "responses"
~~~

Fields available on `[model_providers.<id>]`: `name`, `base_url`, `env_key`,
`env_key_instructions`, `wire_api`, `query_params`, `http_headers`,
`env_http_headers`, `request_max_retries`, `stream_max_retries`,
`stream_idle_timeout_ms`, `websocket_connect_timeout_ms`, `auth`, `aws`,
`experimental_bearer_token`, `supports_websockets`, `supports_standalone_web_search`,
`requires_openai_auth`.

### `wire_api` accepts exactly one value, and this matters

On Codex CLI 0.153.0, `responses` is the **only** accepted value. Verified against the
binary:

~~~text
wire_api = "chat"   -> `wire_api = "chat"` is no longer supported.
                       How to fix: set `wire_api = "responses"` in your provider config.
wire_api = "openai" -> unknown variant `openai`, expected `responses`
~~~

The published config schema agrees. `WireApi` there is a `oneOf` with a single variant:

~~~json
{"description": "Wire protocol that the provider speaks.",
 "oneOf": [{"description": "The Responses API exposed by OpenAI at `/v1/responses`.",
            "enum": ["responses"], "type": "string"}]}
~~~

The binary's own rejection message links
<https://github.com/openai/codex/discussions/7782> for the removal of `chat`.

**The practical consequence is the important part.** Codex speaks the OpenAI
**Responses** API to a custom provider, not chat-completions. An endpoint that exposes
only `/v1/chat/completions` cannot be used as a Codex model provider on this version, no
matter how "OpenAI-compatible" it advertises itself to be. Before wiring the `flash` or
`glm` lane, confirm your endpoint speaks the Responses API — or put a gateway in front of
it that does.

Check your own version before assuming this still holds:

~~~sh
codex --version
printf '[model_providers.probe]\nname = "p"\nbase_url = "https://example.invalid/v1"\nenv_key = "K"\nwire_api = "chat"\n' > "$TMPDIR/probe/config.toml"
CODEX_HOME="$TMPDIR/probe" codex exec --strict-config --skip-git-repo-check -C /tmp "hi"
~~~

`--strict-config` is what surfaces the rejection; `codex doctor` does not validate this
field and will accept any string, including nonsense.

**The key lives in the environment, never in this repository.** `env_key` names an
environment variable. Do not paste a key into a profile, a specification packet, a
call sheet, or any file here.

## Point a lane at a provider

The durable way is to add one line to the installed lane profile:

~~~toml
# $CODEX_HOME/agents/fablewright-glm-implementer.toml
model_provider = "zai"
~~~

`install-agents.sh` treats exactly this - the shipped template plus one appended
`model_provider` line - as a supported CUSTOMIZED state. It passes `--check`, it is
never overwritten, and it is the only difference the installer will tolerate. Any other
edit is still a conflict.

~~~sh
$ sh scripts/install-agents.sh --host codex --check
  CUSTOMIZED: glm-implementer pins model_provider="zai"; otherwise byte-exact.
CHECK PASSED: all codex roles match ..., apart from the provider customizations listed above
~~~

Or per invocation:

~~~sh
scripts/cast-call.sh --lane glm --provider zai < spec.txt
~~~

Or, when you are running from a clone of this repository, by mapping it once in
`hosts/codex/lane-providers.tsv` (one level above the profiles, and read only by
`cast-call.sh`):

~~~text
glm-implementer	zai
glm-reviewer	zai
flash-implementer	opencode-go
~~~

Precedence is `--provider`, then the lane profile's own `model_provider`, then the
sidecar file, then whatever the host is already using.

The sidecar is **repo-relative**: `install-agents.sh` ships lane profiles and nothing
else, so there is no `lane-providers.tsv` beside your installed profiles in
`$CODEX_HOME`. After installing, the profile's own `model_provider` line is the option
that keeps working — and it is the one a natively spawned agent reads anyway. `--check` shows which source
supplied the id:

~~~sh
scripts/cast-call.sh --lane glm --check
~~~

## The provider is verified, not assumed

When you name a provider, `cast-call.sh` reads the thread's rollout after the run and
compares the observed `model_provider` against what you asked for. A mismatch is a
refusal, not a warning: you do not get the worker's output back labelled as if it had
been routed correctly.

The same applies to model, effort, and sandbox. A verified run reports:

~~~text
routing: verified model=glm-4.6 effort=... provider=zai sandbox=workspace-write thread=<uuid>
~~~

`--ephemeral` persists no session, so there is nothing to inspect. FABLEWRIGHT then
reports `routing: waived` rather than claiming a proof it does not have.

## A profile alternative

If you prefer a named profile over per-invocation flags:

~~~toml
[profiles.glm]
model = "glm-4.6"
model_provider = "zai"
sandbox_mode = "workspace-write"
~~~

Then `codex exec -p glm ...`. This works, but it moves the pin out of the lane profile,
so the single source of truth is split across two files. Prefer `--provider`.

## If your endpoint only speaks chat-completions

That lane stays unavailable, and FABLEWRIGHT reports it as a blocker rather than routing
its work to a lane that happened to answer. Your options, in order of honesty:

1. Use an endpoint or gateway that exposes the OpenAI Responses API.
2. Run that lane from the Claude Code host through a different runtime you control, and
   do not claim it as a Codex lane.
3. Drop the lane and record on the call sheet that no cross-family reader is available,
   so `independence: same-family` is carried as residual risk.

What you must not do is repoint the lane at a model that is not the one the profile
pins. The whole verification chain assumes the pin is the truth.

## When a lane has no provider

Report it. On the call sheet, an unconfigured lane is a blocker:

~~~text
FABLEWRIGHT CALL SHEET
route: full
cast: terra
reader: fablewright_sol_reviewer
independence: same-family
risk: <...>. The glm lane has no configured provider, so cross-family review is
      unavailable and same-family review is recorded as residual risk.
~~~

Never hand a stopped lane's work to whichever lane happened to answer.
