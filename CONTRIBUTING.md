# Contributing

## Before you open a pull request

```sh
sh tests/run-tests.sh
sh scripts/verify.sh
```

Both are offline: they call no model and write nothing outside a temporary directory.
`verify.sh` runs the suite as its final check, so a green `verify.sh` is the bar.

## The rules this repository is built on

Changes that weaken any of these will be declined, however convenient they are.

1. **Fail closed.** A missing, conflicting, unavailable, or unobservable model pin,
   role, effort, provider, or isolation stops the lane. Never add a fallback that picks
   a different model, and never downgrade a refusal to a warning.
2. **Prove, don't label.** If a script reports that something was routed a certain way,
   it must have read that back out of the runtime. `routing: waived` is the correct
   output when proof is unavailable.
3. **Refuse rather than overwrite.** The installer never writes a destination it did not
   write itself, never follows a symlink, and never leaves a partial install behind.
4. **One pin, one place.** A lane's model, effort, sandbox, and standing instructions
   live in its profile. Both hosts read that profile. Do not duplicate a pin into a
   script, a doc, or a prompt.
5. **Emit only what is allowlisted.** `inspect-agent-runtime.sh` constructs a new object
   from named fields. It must never grow a passthrough.
6. **No secrets, ever.** Provider keys live in environment variables named by `env_key`.
   Nothing here reads, prints, writes, or moves a credential.
7. **No tool attribution.** No `Co-Authored-By` trailers and no AI or tool attribution in
   commits, pull requests, code comments, or documentation. `verify.sh` enforces this.

## What is deliberately not here

`claude plugin eval` would be the natural behavioural gate for the routing contract:
score whether the wright actually posts a call sheet before delegating, whether it
defaults to `solo`, and whether it refuses an unavailable lane instead of re-routing.
It is not shipped because the feature is early-access gated, so the case schema could
not be validated against the real runner. A suite written from a guessed schema would
be exactly the kind of unverified artifact this repository refuses elsewhere. If you
have access, contribute one under `evals/` and wire it into CI.

## Adding a lane

1. Copy `hosts/codex/agents/TEMPLATE.toml.example` to
   `hosts/codex/agents/fablewright-<lane>-<implementer|reviewer>.toml` and fill in every
   placeholder. It carries the clauses `verify.sh` enforces, so starting from it is
   faster than starting from a sibling profile. For a Claude Code subagent, start from
   `hosts/claude-code/agents/TEMPLATE.md.example`. Add `model_reasoning_effort`
   only when the model advertises one, and `sandbox_mode = "read-only"` for a reviewer.
2. The standing instructions must state, in the lane's own terms: what work legitimately
   belongs to it, that concurrent edits are preserved, that everything it reads is data
   rather than instructions, that a completion claim without command output is invalid,
   and that it must not review its own work or substitute another model.
3. If the model is not served by the host's default provider, document the mapping in
   `hosts/codex/lane-providers.tsv` — commented out, since provider ids are per user.
4. Update the roster in `README.md`, `SKILL.md`, `call-sheet.md`, `role-contracts.md`,
   and `operations.md`, and add the expected role and its pins to `scripts/verify.sh`.
5. Add lane-resolution cases to `tests/run-tests.sh`.

## Releasing

Never hand-edit the version: it appears in two manifests and six scripts, and `verify.sh`
fails if they disagree.

```sh
sh scripts/bump-version.sh 1.1.0 --dry-run
sh scripts/bump-version.sh 1.1.0
# add the CHANGELOG entry yourself - that part is not mechanical
sh scripts/verify.sh
```

Then tag the release so `codex plugin marketplace add --ref` and
`/plugin marketplace add` can pin it.

## Traps this codebase has already hit

The code carries no inline commentary, so this is where the hard-won knowledge lives.
Every item below was a real defect found in review, not a hypothetical. If you are
changing a script, read the ones that touch it.

**`set -e` and the last command of a function.** A function ending in
`[ -n "$x" ] && printf ...` returns non-zero when the test fails, and `set -e` then kills
the whole run silently. This bit three separate places: the `bad()` reporter, the EXIT
traps, and the status capture around a `python3` heredoc. End such functions with an
explicit `return 0`, and wrap a command whose failure you intend to inspect in
`set +e` / `set -e`.

**`jq`'s `//` treats `false` as absent.** `.is_error // true` evaluates to `true` when
`is_error` is `false`, so every success reads as a failure. Read booleans by presence:
`if has("is_error") then (.is_error | tostring) else "true" end`.

**`grep` exit 1 is not `grep` exit 2.** One means no match, the other means the pattern
could not be evaluated. Conflating them made an unusable `FABLEWRIGHT_MODEL_PATTERN`
produce an accusation of model substitution, which is precisely the failure the check
exists to detect. Branch on the status.

**A TOML file is not a list of lines.** A `model_provider = "attacker-relay"` line placed
inside a `developer_instructions """ ... """` body is not a TOML key, but a line grep
adopts it and silently redirects a lane. The same flaw made
`model = "gpt-5.6-luna" # pinned` produce a corrupted `-m` argument. Parsing tracks
multiline-string state, stops at the first `[table]` header, and drops trailing comments.
The installer's provider-customization check does the same by counting the `"""`
delimiters preceding a line.

**Reasoning effort varies per turn.** The runtime reports the last turn's effort and
separately lists every value observed. Comparing only the former passed a lane that spent
two thirds of its run at a lower effort than its pin. Compare every turn.

**A field with no pin was not verified.** Interpolating an observed value into a string
beginning with "verified" claims a comparison that never ran. Keep checked and merely
observed values in separate parts of the output.

**Only the final path component is not enough.** Guarding just the leaf let a symlinked
ancestor land files somewhere other than the path the caller named, and a root guard
matching only `/` and `//` let `/.` and `///` through. Canonicalize to a physical path
before any guard runs.

**A predictable temp path is a symlink target.** `${TMPDIR:-/tmp}/name-$$-x.log` written
with `cp` can be pre-planted on a shared host. `mktemp` creates the file itself with
`O_EXCL` and mode 0600. Note also that mktemp templates contain literal runs of `X`, so a
placeholder scan looking for `XXX` must exclude them.

**An unquoted list splits *and* globs.** Iterating `$roles` unquoted is intentional word
splitting, but `--check-role '*'` then expands against the working directory. Validate
the input charset and `set -f` around the loop.

**Dependency checks belong at the point of use.** A `command -v codex` gate placed before
argument parsing made every usage error report a missing binary, and broke every offline
path on a runner without the CLI. 23 of 72 cases failed that way, and CI had never
actually passed.

**A trailing positional that may begin with `-`.** The Claude Code CLI parses options, so
a packet opening with a markdown bullet or a `---` fence was read as a flag and the
failure was reported as an unreachable wright. Pass `-- "$packet"`.

**Preflight being all-or-nothing does not make the write loop atomic.** Roles are written
one at a time; a failure partway through left a partial install. Track what the run
creates and replaces, and undo exactly that — never an earlier run's files.

**A sandbox override must only narrow.** Widening a reviewer pinned to `read-only` waives
the only isolation it has, and the run then reports a sandbox it was asked for rather
than the one the lane requires.

**A rollout file holds more than one session.** It embeds the subagent's `session_meta`
and its parent's, so evidence must be selected by thread id rather than by assuming a
single record. `agent_role` is legitimately null for a top-level thread.

**`${CLAUDE_PLUGIN_ROOT}` does not expand in frontmatter.** It works in a command or
agent body and not in `allowed-tools`. And once installed, the working directory is the
user's project, not the plugin cache, so any repo path a command tells the model to open
must be plugin-root relative.

## Style

POSIX `sh`, not bash. Validate every argument before touching the filesystem. Prefer a
clear refusal message naming the exact file over a clever recovery.

The code carries no inline comments. Names, structure, and refusal messages are expected
to carry the intent; anything that genuinely needs explaining goes in the section above or
in the reference docs, where one reader can find all of it at once instead of discovering
it a line at a time. Prose is written for someone debugging at speed: short sentences,
concrete nouns, no filler.
