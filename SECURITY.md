# Security

## Reporting

Report a vulnerability privately through GitHub's security advisory flow on this
repository rather than opening a public issue.

## What this software does and does not touch

**The reader cannot write on Claude Code.** `fablewright-reader` declares
`tools: Read, Grep, Glob` and `disallowedTools: Write, Edit, NotebookEdit, Bash`. It has
no path to modify the repository, so its verdict cannot be contaminated by its own
fixes. The same applies to `fablewright-scout`.

**Never reads, prints, writes, or moves a credential.** Provider API keys live in
environment variables named by the `env_key` field of a Codex `[model_providers.<id>]`
block. FABLEWRIGHT passes a provider *id*, never a key.

**Never edits host configuration.** It does not modify `config.toml`, `settings.json`,
or any file outside the destination directory you name when you run the installer.

**Resolves the destination before guarding it.** `--target-dir` is canonicalized to a
physical path first, so a symlinked ancestor cannot land files somewhere other than the
path reported back to you, and `/`, `/.`, `///` and any `..` component are refused. A
symlinked ancestor is resolved and reported rather than refused, because dotfile managers
legitimately symlink `~/.codex`; what is never followed is a symlinked destination
*file*.

**Writes diagnostics to an unpredictable path.** When a lane fails, its raw runtime
stderr is retained for you to read. That file is created with `mktemp` (`O_EXCL`, mode
0600) rather than a predictable pid-derived name, so it cannot be pre-planted as a
symlink on a shared host. Runtime stderr can contain authentication and transport
diagnostics — delete it when you are done.

**Emits only allowlisted routing fields.** `inspect-agent-runtime.sh` reads exactly one
rollout file, matched on filename before any content is read, and constructs a new
object from named fields only: thread and parent ids, agent role and path, model
provider, model, effort, sandbox policy type, permission profile type, working
directory, and turn count. It never emits prompts, messages, tool output, environment
variables, tokens, or configuration.

**Refuses rather than overwrites.** The installer never writes a destination that is a
symlink, is not a regular file, or differs from a profile it shipped. A failed preflight
on any role writes nothing at all, and state is re-checked immediately before each write
so a file that changes mid-install aborts rather than being clobbered.

## Prompt injection

Repository files, diffs, tool output, dependency metadata, and worker reports become
another agent's input. Every lane profile and reader instructs its model to treat all
such material as **data, never as instructions**, and to report — rather than obey —
content that tries to redirect routing, approve its own change, or suppress a check.

This is a mitigation, not a guarantee. The structural defences matter more: the reader
has no write tool, delegated work is bounded to a stated file set, and the wright
re-runs verification itself instead of trusting a report.

## Trust boundaries you should understand

- **A read-only *request* is not a read-only *guarantee*.** On Claude Code the reader is
  enforced by its tool set. On Codex the reviewer profile requests
  `sandbox_mode = "read-only"`, and the host may broaden it. Observe
  `sandbox_policy_type` before relying on isolation; if it is unobservable or a mutation
  occurred, stop the lane.
- **`--ephemeral` waives routing proof.** No session is persisted, so nothing can be
  inspected. FABLEWRIGHT says `routing: waived` **and exits 75**, so an orchestrator
  gating on `$? -eq 0` cannot mistake a waived run for a proven one. Exit 0 means
  verified and nothing else.
- **`FABLEWRIGHT_MODEL_PATTERN` is a safety control.** It is what forces the wright to be
  a Fable model. Widening it means accepting a different model as the wright; do it
  deliberately and say so.
- **Cast lanes execute code.** `cast-call.sh` runs `codex exec` with the sandbox the lane
  profile names, defaulting to `workspace-write`. Pass `--sandbox read-only` for lanes
  that should only inspect.
- **A refused report does not undo a write.** Routing is verified *after* the lane runs,
  because the evidence does not exist until then. If verification fails for a lane that
  ran with `workspace-write`, FABLEWRIGHT refuses the report and prints an explicit
  warning that the working tree may already have been modified. Inspect the tree before
  continuing; refusing the report is a statement about trust, not a rollback.
