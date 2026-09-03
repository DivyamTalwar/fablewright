---
description: Run the fresh read-only FABLEWRIGHT reader over the accumulated change set
argument-hint: "[base-ref]  (default: the current working-tree diff)"
allowed-tools: Bash, Read, Grep, Glob, Agent
---

Obtain an independent verdict on the current change set. You are the wright here: you
do not write the review, and you do not accept the change on your own say-so.

Base for the diff: $ARGUMENTS (default: the working tree).

1. **Verify first, then read.** Re-run the project's checks yourself and capture the
   actual output. This step is why the command allows `Bash` rather than a git-only
   allowlist: a reader handed evidence the wright could not reproduce is reviewing a
   claim, not a change. A reader handed unverified work returns a verdict about nothing. If
   you have not run the checks, run them before continuing.

2. Collect the complete accumulated change set: `git status --short` and the full diff
   against the base. Note which lane authored it and its model family.

3. Delegate to the `fablewright-reader` subagent with the reader packet from
   `${CLAUDE_PLUGIN_ROOT}/skills/fablewright/references/role-contracts.md`: stated goal,
   author and family,
   the complete change set, interfaces and constraints, and the verification evidence
   **you reproduced**.

4. Report the returned block verbatim:

```text
FABLEWRIGHT READ
VERDICT: ship | fix-first | rethink
REASON: ...
FINDINGS: ...
INDEPENDENCE: cross-family | same-family
RESIDUAL RISK: ...
```

Then act on it. `ship`: report completion with the evidence. `fix-first`: the author's
lane makes the correction — never the reader — then you re-verify and obtain a **new**
reader. `rethink`: revise the architecture and do not report completion.

Any fix invalidates the verdict you just received. Do not carry a stale `ship` across a
change.
