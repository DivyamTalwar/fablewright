## What this changes

<!-- One or two sentences. What is different after this merges? -->

## Why

<!-- The problem. If this is a fix, what was actually wrong. -->

## Evidence

Both gates are offline — they call no model and write nothing outside a temporary
directory. Paste the real output, not a claim that you ran them.

```
$ sh tests/run-tests.sh

$ sh scripts/verify.sh
```

- [ ] `shellcheck --severity=warning scripts/*.sh tests/*.sh` is clean
- [ ] New behaviour has a test that fails without the change
- [ ] Docs updated if this changes what a command does or promises

## Checked against the rules in CONTRIBUTING.md

- [ ] **Fail closed** — no new fallback picks a different model, and no refusal was
      downgraded to a warning
- [ ] **Prove, don't label** — anything reported as verified was read back from the
      runtime; `routing: waived` is the correct output when proof is unavailable
- [ ] **Refuse rather than overwrite** — the installer still writes nothing it did not
      write itself, and leaves no partial install behind
- [ ] **One pin, one place** — a lane's model, effort, sandbox and provider live in its
      profile and are not duplicated into a script, doc or prompt
- [ ] **No secrets, no tool attribution**
