---
description: Bootstrap FABLEWRIGHT on this machine - check what is present, install the lane profiles, and say plainly what is optional
argument-hint: "[--check]  (report only, install nothing)"
allowed-tools: Bash, Read
---

Get this machine from "just installed the plugin" to "ready to route work". Report what
is true; do not overstate readiness.

Arguments: $ARGUMENTS (if `--check`, report only and install nothing).

## 1. What is present

```
claude --version
codex --version
jq --version
```

Interpret honestly:

- **No `claude`** — the wright cannot be reached. On this host the wright is the session
  model, so this only matters for `${CLAUDE_PLUGIN_ROOT}/scripts/ask-wright.sh`, which
  the Codex host uses. Note it and continue.
- **No `codex`** — cast lanes are unavailable, because Claude Code subagents run Claude
  models. The reader, the scout, and every routing decision still work. This is a
  reduced install, not a broken one: say so.
- **No `jq`** — a hard stop for `cast-call.sh` and `ask-wright.sh`. Tell the user to
  install it; the scripts refuse to guess without it.

## 2. Prove the wright

```
${CLAUDE_PLUGIN_ROOT}/scripts/ask-wright.sh --check
```

Passes only when a Fable model actually served the call. If the session is not Fable 5.1,
say so and tell the user to switch — a skill cannot change the host's model.

## 3. Install the lane profiles

Only needed for the Codex host. Installing the plugin registers skills, not user-owned
agent profiles, so this step is separate and deliberate.

Show what would change before changing anything:

```
sh ${CLAUDE_PLUGIN_ROOT}/scripts/install-agents.sh --host codex --dry-run
```

If the user approves, install and verify:

```
sh ${CLAUDE_PLUGIN_ROOT}/scripts/install-agents.sh --host codex
sh ${CLAUDE_PLUGIN_ROOT}/scripts/install-agents.sh --host codex --check
```

**Before install, `--check` reporting every role as `missing` is the correct state, not a
failure.** Do not present it as one. A `conflict` is different: it means a profile was
edited, and you should show the user which and stop rather than overwrite it.

## 4. Which lanes can actually serve work

```
${CLAUDE_PLUGIN_ROOT}/scripts/cast-call.sh --lane luna  --check
${CLAUDE_PLUGIN_ROOT}/scripts/cast-call.sh --lane terra --check
${CLAUDE_PLUGIN_ROOT}/scripts/cast-call.sh --lane flash --check
${CLAUDE_PLUGIN_ROOT}/scripts/cast-call.sh --lane glm   --check
```

`--check` proves the pin, not that a provider can serve it. `flash` and `glm` need a
provider speaking the OpenAI Responses API; without one they are unavailable, which is a
blocker to report on a call sheet and never a reason to route their work elsewhere. Point
the user at `${CLAUDE_PLUGIN_ROOT}/skills/fablewright/references/providers.md`.

## 5. Report

A short table: `wright`, `luna`, `terra`, `flash`, `glm`, `sol-reviewer`, `glm-reviewer`
— each `ready`, `needs a provider`, or `blocked: <reason>`.

Then state which routes are available given what is ready. If no cross-family reader is
callable, say so explicitly: it changes what the `independence` field on a call sheet is
allowed to claim.

End with the single next command the user should run. If everything needed for `solo` and
`audit` works, that is a usable install — say so rather than listing what is missing.
