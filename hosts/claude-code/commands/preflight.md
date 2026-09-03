---
description: Prove the FABLEWRIGHT wright and every lane profile before delegating anything
argument-hint: "[lane ...]  (default: check every lane)"
allowed-tools: Bash, Read
---

Run FABLEWRIGHT preflight and report what is actually callable right now. Check, do not
assume, and do not delegate anything as part of this command.

This command diagnoses an install; it does not create one. If nothing is installed yet,
say so and point at `/fablewright:setup` rather than reporting a wall of failures.

Lanes to check: $ARGUMENTS (if empty, check all of them).

1. Prove the wright:
   `${CLAUDE_PLUGIN_ROOT}/scripts/ask-wright.sh --check`
   This sends no packet, prints no plan, and runs at low effort. It passes only when a
   Fable model actually served the call.

2. Confirm the lane profiles are byte-exact:
   `sh ${CLAUDE_PLUGIN_ROOT}/scripts/install-agents.sh --host codex --check`

   Read the result carefully rather than treating a non-zero exit as breakage:
   - every role `missing` — nothing is installed yet. That is the correct state before
     setup, not a fault. Tell the user to run `/fablewright:setup` and stop here.
   - a `conflict` — someone edited an installed profile. Report which, and do not repair
     it.
   - `CUSTOMIZED` — a profile carries a `model_provider` pin. That is supported; report
     the provider and carry on.

3. Confirm each lane's pin:
   `${CLAUDE_PLUGIN_ROOT}/scripts/cast-call.sh --lane <lane> --check`
   for luna, terra, flash, glm, and `--kind reviewer` for sol and glm.

Then report a short table: lane, model, effort, provider, and one of `callable`,
`profile ok / provider unconfigured`, or `blocked` with the reason.

State plainly which lanes could serve as a **cross-family reader** given the lanes that
are callable. If no cross-family reader is available, say so — it changes what the
`independence` field on a call sheet is allowed to claim.

`--check` proves a pin, not that a provider can serve it. Say that in your summary
rather than implying more confidence than the checks earned.
