# The call sheet

How the wright decides who is called to set, and why the default answer is nobody.

## The delegation test

The cost of delegating is the specification. If specifying the work correctly requires
solving it first, delegation has already spent the expensive part and buys nothing but
a second chance to be misunderstood.

Delegate only when at least one is clearly true:

- **Execution dwarfs specification.** The transformation is short to describe and long
  to apply - a codemod across 90 files, a repetitive scaffold, an exhaustive sweep.
- **The work would pollute the wright's context** with detail it will not need again,
  and the result is checkable without that detail.
- **The work is genuinely independent** of everything else in flight, over files nobody
  else is touching.

Do not delegate when:

- The goal is still moving. Exploration is the wright's job; you cannot specify a
  question.
- Verification costs about what doing it costs. Then delegation only adds a handoff.
- The lane would need context the wright would have to assemble anyway.
- Two lanes would need the same file. That is one sequential task wearing a disguise.

When the test fails, `solo` is the correct route and posting it is a success. A system
that always delegates has stopped routing and started performing.

## Choosing the route

Work down this list and stop at the first match.

1. Bounded, low-risk, reversible, and cheap to redo if wrong -> **`solo`**.
2. The wright is the fastest author, but the change is hard to reverse, touches
   security, money, data integrity, or a public contract, or the wright has been deep
   in this code long enough to have lost perspective -> **`audit`**.
3. The delegation test passes, and the change is bounded and low-to-moderate risk ->
   **`delegate`**.
4. The delegation test passes, and the change is judgment-heavy, hard to reverse, or
   wide in blast radius -> **`full`**.
5. The delegation test passes for two or more pieces at once, ownership is **provably
   disjoint**, an integration step is written before anyone starts, and every lane comes
   from **one model family** so a single reader can be independent of the whole combined
   change set -> **`ensemble`**.

Never reach `ensemble` by accumulating single delegations. Either the parallel structure
was true at planning time and was declared, or the work is sequential.

## Choosing the lane

| the work is | lane | why |
|---|---|---|
| bounded, fully specified, ordinary implementation | `luna` | routine lane at maximum effort; the spec determines the answer |
| judgment-heavy, high-risk, context-heavy, wide blast radius | `terra` | escalation lane; latitude for judgment inside the settled architecture |
| a known transformation applied many times | `flash` | throughput lane; correctness is checkable by command |
| implementation where cross-family independence is wanted, or no GPT-5.6 on this host | `glm` | independent lane; also the fallback roster on non-OpenAI hosts |

Classify by the **pinned model** in the lane profile, never by a display name. A lane is
its pin.

Never route judgment to `flash`. If the task requires deciding what the right answer is
rather than applying a known answer repeatedly, it is not throughput work.

## Escalation

A route may escalate. It may never quietly relax.

- Escalation requires **newly observed** risk, and the call sheet must be re-posted with
  that evidence in the risk line.
- A `luna` result escalates to `terra` when its `ESCALATION SIGNAL` is non-empty, or when
  the diff shows complexity, risk, or blast radius the specification did not anticipate.
- A specification error earns **one** corrected attempt in the same lane. That retry is
  not a prerequisite for escalating, and a second failure of the same specification is a
  wright problem, not a lane problem.
- `solo` and `delegate` do not acquire a reader retroactively. If a read is warranted,
  escalate to `audit` or `full` and say so on a new call sheet.
- Downgrading a posted route requires the same standard as escalating: state the
  evidence. Silence is not a downgrade, it is a defect.

## Preflight matrix

Confirm the wright first. Then preflight **only** the lanes the posted call sheet
actually calls. Every check is non-mutating and fail-closed; cache a passing check for
the current task only.

| route | lanes to preflight |
|---|---|
| `solo` | none |
| `delegate` | the one selected cast lane |
| `audit` | the selected reader |
| `full` | the selected cast lane and the selected reader |
| `ensemble` | every called cast lane and the selected reader |

A missing, stale, modified, conflicting, unavailable, or unobservable lane profile stops
that lane. Report the blocker. Never re-route the work to a lane that happened to pass.

Exact commands are in [operations.md](operations.md).

## The cost you are spending

Agents use roughly four times the tokens of a chat turn, and multi-agent systems roughly
fifteen times. That budget is only justified when the work is genuinely broad or the
outcome is genuinely valuable. Published experience is consistent that **most coding
tasks do not parallelize well**, and that parallel agents fail by miscommunicating
subtasks and by making conflicting implicit decisions that neither can see.

Both findings point the same way and the routes encode it: decide before you spawn,
spawn as little as possible, and make the seams somebody's explicit job.

## Anti-patterns

Each of these looks like orchestration and is not.

- **Delegating to look thorough.** One agent that finishes beats three that coordinate.
  If you cannot name what the lane does that the wright would otherwise do, do not spawn
  it.
- **Duplicating instead of substituting.** If the wright re-does the lane's work to
  check it, the lane was never load-bearing. Verification means re-running the checks
  and reading the diff, not re-implementing.
- **Splitting a decision across contexts.** Two lanes making the same implicit choice
  independently will make it differently, and the seam is where it surfaces. Decisions
  belong to the wright, before the spawn.
- **Reviewing your own performance.** Same agent, same context, no independence. The
  verdict is worth what it cost.
- **Same-family review reported as independence.** Fresh context removes the author's
  memory, not the family's shared blind spots. Record it as `same-family` and move on.
- **Silent substitution.** An unavailable lane is a blocker to report, never a reason to
  quietly hand the work to whichever lane answered.
- **Serial spawns imitating parallelism.** Sequential delegations are `delegate`
  repeated, not `ensemble`. Do not claim parallel execution you did not run.
