---
description: Post a FABLEWRIGHT call sheet for a task before any delegation happens
argument-hint: <the task to route>
allowed-tools: Read, Grep, Glob
---

Decide how to deliver this task and post exactly one call sheet. This is the routing
decision only: read what you need to judge the risk, then post the sheet. You have no
write, execution, or delegation tool here, which is deliberate — the command that decides
whether to delegate must not be able to start delegating.

Task: $ARGUMENTS

Load `${CLAUDE_PLUGIN_ROOT}/skills/fablewright/references/call-sheet.md` and apply it
honestly, in order:

1. **Run the delegation test first.** If specifying the work requires solving it,
   delegation buys nothing. If the wright would have to do the task anyway to check it,
   the route is `solo`.
2. Work the decision list in `call-sheet.md` **in order** and stop at the first match:
   `solo`, `audit`, `delegate`, `full`, `ensemble`. That order is cheapest-first
   precedence, not the enumeration order you see elsewhere in the docs - the sheet lists
   the routes alphabetically-by-escalation, this list ranks them by what to try first.
3. Pick lanes by work shape, classifying by the pinned model and never by a display
   name. Never route judgment to `flash`.
4. Set `independence` from the reader's family versus the author's family. Same-family
   is context-clean, not independent — say so rather than rounding it up.

Post:

```text
FABLEWRIGHT CALL SHEET
route: solo | delegate | audit | full | ensemble
cast: none | <lane-id>[, <lane-id>...]
reader: none | <lane-id>
independence: cross-family | same-family | not-applicable
risk: <concise, task-specific rationale>
```

The sheet must be internally consistent: `audit` has no cast, `delegate` has no reader,
`ensemble` needs two or more lanes over provably disjoint ownership plus a written
integration step.

Then, in two or three sentences, say what would have to be observed to justify
escalating this route later. Escalation requires new evidence; it is not a mood.

If `solo` is right, post `solo` and say why. That is the correct answer more often than
not, and it is a result, not a failure.
