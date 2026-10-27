---
name: delivery-pipeline
description: Drives one change through ordered evidence gates — independent review, security review, risk scoring, human approval when risky, CI, merge queue, and staged rollout — with a fixer loop capped at three rounds. Use when shipping a change end to end, when asked to "run the pipeline", "take this branch to production", or "review and merge this", or when CI or a rollout failed and an agent must repair it unattended.
---

# Delivery Pipeline

## Overview

A change reaches production in one direction only: review, security, risk,
human (when risky), CI, merge queue, rollout. Each gate runs in a fresh
context, writes an artifact, and returns a verdict. A failed verdict goes to
the fixer, who repairs and sends the change back to the gate that rejected it.

Progress is the easy part. The hard part is stopping correctly: refusing to
advance on a stale SHA, refusing to merge on a green run from an old base, and
refusing to keep fixing after three failed rounds. Every rule below exists to
make those stops cheap and honest.

The gates do not invent their own criteria. Each delegates to an existing
skill, so this skill owns the **sequence, the evidence, and the stop rules** —
not the review method itself.

## When to Use

- A change is authored and must cross independent gates before production
- CI, the merge queue, or a rollout failed and repair must run unattended
- A change needs a decision: human review, or straight to CI
- Auditing or designing an agent delivery process

NOT for:

- One review pass with no gates after it → use `code-review-and-quality`
- A launch checklist with no state machine → use `shipping-and-launch`
- Building the CI pipeline itself → use `ci-cd-and-automation`
- Deciding what to build → use `spec-driven-development` first

## The Sequence

```
author + tests
   │
   ▼
review  ──fail──► fixer
   │ pass
   ▼
security ──fail──► fixer
   │ pass
   ▼
risk ──high──► human ──reject──► fixer
   │ low/medium          │ approve
   ▼                     ▼
   └─────────────────────┴──► push → CI ──fail──► fixer
                                    │ pass
                                    ▼
                             merge queue ──eject──► fixer
                                    │ merged
                                    ▼
                    rollout: testers → wider → everyone
                                    │ breaks
                                    ▼
                               rollback ──► fixer
                                    │
                            fixer ──► back to the failed gate, new context
```

Order is fixed. Nothing is skipped, nothing is reordered, and no gate reads
the previous gate's prose as evidence.

## The Change Record

The `/pipeline` command runs this sequence; this skill defines the gates,
the evidence, and the stop rules it enforces.

One directory per change. It is the only source of truth about where the
change stands; never infer the phase from memory or a branch name. Several
changes may be in flight, each with its own record; the merge queue serialises
them and every gate reads only its own record.

```bash
bash skills/delivery-pipeline/scripts/pipeline.sh init my-change
bash skills/delivery-pipeline/scripts/pipeline.sh status
bash skills/delivery-pipeline/scripts/pipeline.sh next
bash skills/delivery-pipeline/scripts/pipeline.sh gate review pass
bash skills/delivery-pipeline/scripts/pipeline.sh gate security fail
bash skills/delivery-pipeline/scripts/pipeline.sh gate risk high
bash skills/delivery-pipeline/scripts/pipeline.sh human approve "morta"
bash skills/delivery-pipeline/scripts/pipeline.sh rollback-plan "error rate > 2x baseline" "kubectl rollout undo deploy/api" "oncall"
bash skills/delivery-pipeline/scripts/pipeline.sh rollback-tested
bash skills/delivery-pipeline/scripts/pipeline.sh check     # exit 1 when not safe to push
bash skills/delivery-pipeline/scripts/pipeline.sh sync      # HEAD moved: stale every gate
```

The script writes `.pipeline/<change-id>/state.json` and holds the invariants:
gate order, the three-round cap, and SHA staleness. Keep `.pipeline/` out of
git. Requires `jq`.

| File | Written by |
|---|---|
| `state.json` | the script |
| `bundle.md` | the orchestrator, before each gate |
| `review.md` | `change-reviewer` |
| `security.md` | `change-security-reviewer` |
| `risk.md` | the orchestrator, from the rubric |
| `round-<n>.md` | `change-fixer` |
| `rollout.md` | `release-manager` |
| `handback.md` | the orchestrator, when the pipeline stops |

## Core Process

### 1. Open the record

```bash
bash skills/delivery-pipeline/scripts/pipeline.sh init
```

The base is the merge-base against the default branch. The head is the current
`HEAD`. Record the change summary in one paragraph, in the author's words and
without self-assessment.

### 2. Review gate

Dispatch the **change-reviewer** persona in a **new context**. It invokes
`code-review-and-quality` and returns `PASS` or `FAIL`, the files it read,
blocking findings with `file:line`, and a not-verified list.

```bash
bash skills/delivery-pipeline/scripts/pipeline.sh gate review pass
```

Pass requires zero blocking findings. "Looks good" without a file list is a
`FAIL` — the reviewer did not read the diff.

### 3. Security gate

Dispatch the **change-security-reviewer** persona in another new context. It
invokes `security-and-hardening` and attempts every checklist item, recording
`N/A` with a reason where an item does not apply. Any open problem blocks the
merge; there is no severity that permits merging.

```bash
bash skills/delivery-pipeline/scripts/pipeline.sh gate security pass
```

### 4. Risk gate

Score with the rubric below. This is mechanical: record the inputs, not an
opinion. Any unknown input scores `high`.

```bash
bash skills/delivery-pipeline/scripts/pipeline.sh gate risk low
```

### 5. Human gate — risky changes only

Show the person: diff stat, review verdict, security verdict, the exact rubric
rules that fired, the rollback trigger and command, and the not-verified list.
Ask one question — approve or reject. Do not push while waiting. The script
refuses approval for a `high` tier until a rollback plan is recorded.

```bash
bash skills/delivery-pipeline/scripts/pipeline.sh human approve "name"
```

A rejection goes to the fixer like any other failure. It costs a round.

### 6. Push and CI

Follow `git-workflow-and-versioning` for the commit and push. Wait for CI on
the pushed SHA — not an earlier one.

```bash
bash skills/delivery-pipeline/scripts/pipeline.sh check && git push origin HEAD
gh run watch --exit-status     # or the repo's equivalent
bash skills/delivery-pipeline/scripts/pipeline.sh gate ci pass
```

### 7. Merge queue

The queue retests against the latest base. A pass on the old base does not
count, because it proves a merge that never happens. On eject, take the failure
evidence to the fixer.

```bash
bash skills/delivery-pipeline/scripts/pipeline.sh gate queue pass
```

### 8. Rollout

Dispatch the **release-manager** persona. It invokes `shipping-and-launch` and
`observability-and-instrumentation`, runs testers → wider → everyone, and
records baseline, observed value, and window per stage.

Before stage one, record the rollback trigger and the exact rollback command,
then execute that command once where it is harmless. The script refuses the
rollout gate until the command is marked as executed. An untested rollback
command is a guess.

### 9. Close

```bash
bash skills/delivery-pipeline/scripts/pipeline.sh gate rollout pass
```

Report rounds used, gates that failed, what remains unverified, and the rollout
evidence. "Shipped" means the last stage completed and its window closed.
Anything else is reported by its real stage.

## Fresh Context Rule

Each gate is a separate agent invocation with no continuation of the previous
session. Never pass a session ID to keep the thread warm.

The gate receives a bundle, written to
`.pipeline/<id>/bundle.md`:

- `git diff $BASE...HEAD` and the changed file list
- the author's one-paragraph summary
- the repo path and the commands for tests, lint, and typecheck
- constraints: what must not change, what must stay compatible
- what the author verified, as commands and output

The bundle excludes the author's plan, earlier gate prose, and the fixer's
reasoning. A gate that sees the author's conclusion agrees with it.

For changes that score `high` on the risk rubric, run one extra adversarial
pass with `doubt-driven-development` before the human gate.

## Fixer Loop

Any failure goes to the **change-fixer** persona with the evidence, the diff,
the repo, and the constraint list.

- **Reproduce first.** Follow `debugging-and-error-recovery`: reproduce,
  localize, reduce, fix, guard. No reproduction, no patch.
- **One root cause per round.** The smallest edit that fixes it. No drive-by
  refactor.
- **Three fix rounds per change, total.** A failed verification spends a round
  and dispatches the fixer. A fourth failure stops the pipeline. Edits that are
  not verified spend nothing.
- **The fixer never verifies its own work.** The failed gate reruns in a new
  context.
- **An edit invalidates every gate recorded at the old SHA.** Run
  `pipeline.sh sync`, then re-record from review. Re-runs cost no round; only a
  failed verification does.

Stop and hand back to the author when the third fix also fails, when the same
finding survives two fixes, when the fix needs a design change (new dependency,
schema, API contract), or when a gate cannot run at all. Write `handback.md`: what
failed each round, what was tried, the evidence, and two or three approaches
still open. Then stop — do not open a PR, merge, or roll out.

The fixer must never disable a test, widen an allowlist, or suppress a check to
reach green. That is a handback, not a fix.

## Risk Rubric

Highest matching tier wins. Unknown scores `high`. Only a person may downgrade,
in writing, in `state.json`.

| Tier | Fires when any one is true |
|---|---|
| **High** | auth, sessions, tokens, crypto; payments or money math; migration, schema, backfill, destructive data op; secrets, IAM, CI config, deploy manifests, infra, network policy; new dependency or major bump; public API, wire format, or event schema change; concurrency, locking, queueing, retries, idempotency; flag default-on for all users; more than 400 changed lines or 15 files; changed path with no test that executes it; rollback unknown or untested; the change was rolled back once already |
| **Medium** | new endpoint, command, or user-visible behaviour; config default not for all users; performance-sensitive or cache-invalidation path; cross-module refactor with full coverage; minor or patch dependency bump |
| **Low** | docs, comments, formatting; tests only; single-module refactor with full coverage; clean revert of a low-risk change shipped in the last 24 hours |

Record the inputs so the tier is auditable:

```bash
git diff --shortstat "$BASE"...HEAD
git diff --name-only "$BASE"...HEAD | wc -l
git diff --name-only "$BASE"...HEAD | grep -cE 'migrations/|\.tf$|Dockerfile|\.github/workflows/'
```

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "The reviewer already read this, so the security pass can be quick" | Different question, different failure mode. Review asks "does it work"; security asks "how is it abused". |
| "It is a small diff, skip the human gate" | Size is one rubric input, not the rubric. A three-line auth change is still `high`. |
| "The fix works, re-running the review is a formality" | The fix is the newest untested code in the change. Fresh eyes are the cheapest check you will ever run. |
| "CI was green before the rebase" | Green on an old base proves nothing about the merge. The queue retests for this exact reason. |
| "We are at round three, one more attempt will do it" | Three failures is evidence about the design, not the patch. Hand back. |
| "I will keep the transcript so the next agent has context" | It gives the next agent your conclusion. Pass the diff and the evidence instead. |
| "Rollback will be easy, we can write it during the incident" | Incidents are the worst time to write and first-run a rollback command. |
| "The test is flaky, I will disable it" | Proven flake goes to the author with two reruns of the unmodified SHA. A disabled test is a silent regression. |

## Red Flags

- A gate returns a verdict without naming the files or commands it used
- The reviewer is the author, or the fixer is the verifier
- Security findings marked "pre-existing" and merged anyway
- Risk tier recorded without the `--shortstat` and file-count inputs
- Push before the human answered, "so CI can warm up"
- Merge on a green run whose base SHA is not the current base
- A round counter that increments on edits instead of failed verifications
- Rollout widened before the observation window closed
- The pipeline reported "shipped" when only testers saw the change
- A fourth fix attempt in progress

## Verification

Before declaring the change shipped:

- [ ] `pipeline.sh status` shows every gate `pass` at the current `HEAD` SHA
- [ ] Review artifact names the files read and lists findings with `file:line`
- [ ] Security artifact covers every checklist item, with `N/A` reasons
- [ ] Risk tier recorded with its computed inputs; human approval present when `high`
- [ ] CI log matches the pushed SHA and exits 0
- [ ] Queue retest ran against the current base and the merge SHA is recorded
- [ ] Rollback trigger and command recorded, command executed once before stage one
- [ ] Every rollout stage has baseline, observed value, and window in `rollout.md`
- [ ] Rounds used ≤ 3, or `handback.md` exists and the pipeline is `stopped`
