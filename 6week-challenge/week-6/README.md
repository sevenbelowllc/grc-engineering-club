# Week 6 — Speak the Auditor's Language

The capstone. Five weeks produced proof in engineering formats: Terraform plans,
Rego rules, JSON verdicts, signed tarballs. This week turns that into something
an assessor can consume without a meeting, and closes the loop by proving the
whole graph walks end to end.

**Status:** complete. Five OSCAL documents, all `VALID`; four controls traversed
from profile to verified evidence with all four legs of the chain green.

```
catalog -> profile -> component -> evidence URI -> verified bundle
```

## Run it

From the repository root:

```bash
./verify-pipeline.sh     # all six checks, one verdict
./traverse.sh            # walk the graph, following only the documents
```

Latest local run: **12 passed, 0 failed, 0 skipped**
([transcript](evidence/pipeline-verification.txt)).

## What is here

| | |
|---|---|
| [`oscal/`](oscal/) | The trestle workspace. Profile, component definition, assessment plan, two assessment-results documents. [Start with its README.](oscal/README.md) |
| [`oscal-from-conftest.py`](oscal-from-conftest.py) | Turns conftest verdicts into OSCAL assessment-results. The headline piece — [why it works the way it does](assessment-results.md). |
| [`rebuild-oscal.sh`](rebuild-oscal.sh) | Regenerates every document in the one order that keeps the graph intact. |
| [`sign-oscal.sh`](sign-oscal.sh) | Signs the control mapping itself, so the *claim* is tamper-evident and not just the evidence. |
| [`terraform/`](terraform/) | The keyless CI identity and the WORM evidence vault. [One apply.](terraform/README.md) |
| [`ASSURANCE-BOUNDARY.md`](ASSURANCE-BOUNDARY.md) | What the pipeline does **not** prove. Seven limits, written down deliberately. |
| [`PORTFOLIO-CASE-STUDY.md`](PORTFOLIO-CASE-STUDY.md) | The six weeks presented as one system. |
| [`evidence/`](evidence/) | Transcripts: the four-leg chain, the WORM delete refusal, the converter's guards, the pipeline run. |

## The two documents the brief asks for

**A profile** — the claim, stated as a selection. Four control IDs from NIST
800-53 Rev 5 and nothing else. Controls the build touches incidentally (AU-9,
AU-10, SI-4) are excluded, because a profile that lists controls it cannot prove
devalues the ones it can.

**A component definition** — how each control is implemented. Every
`implemented-requirement` names the Terraform resource that does the work, the
Rego package that gates it, whether it is verified at plan time or at runtime,
and links its evidence twice: a `raw.githubusercontent` copy anyone can fetch
without credentials, and an `s3://` copy in an Object Lock COMPLIANCE vault that
nobody can delete. Either alone is the weaker claim.

Both are pinned to commit `1d97be7`, so every link keeps meaning after the
branch moves on. All 13 HTTP links verified resolving.

## The three that go beyond it

**An assessment plan.** OSCAL makes `import-ap` a required field on
assessment-results, so results need a plan to point at. It turned out to be the
right place to state the method split — three controls assessed by automated
policy evaluation before apply, AU-3 assessed by examining runtime output. That
split is the pipeline's assurance boundary, stated in the model rather than in a
footnote.

**Assessment results, generated not written.** `oscal-from-conftest.py` converts
`{"namespace": "compliance.sc28_aws", "successes": 1}` into
`{"target-id": "sc-28_obj", "status": {"state": "satisfied"}}` mechanically. Its
central design decision is that **the control mapping is not in the converter** —
it is read out of the component definition's `policy-package` props at
conversion time, so a rename that breaks the mapping fails the build instead of
silently dropping a control. It fails loudly in both directions and its output
is byte-identical on re-run. [Full write-up.](assessment-results.md)

**A negative control.** The same converter, run against a plan with the
encryption resources removed, emits `not-satisfied` for SC-28. A pipeline that
has only ever produced passing results has not been shown to be capable of
producing a failing one.

## AU-3 has no policy rule, deliberately

Three controls are enforced at plan time. AU-3 is not, and its `remarks` field
says so at length.

A Terraform plan can show that a CloudTrail trail *will be created*. It cannot
show that the trail is *delivering records*, because delivery is a runtime
property of a system that does not exist yet at plan time. A plan-time rule for
AU-3 would produce a green gate that attests to nothing.

So AU-3's evidence is captured `get-trail-status` output showing `IsLogging:
true` with recent log and digest delivery. That is a **narrower** claim than the
plan-time controls make — true of one moment, not of every future pull request —
and a **stronger** one, because it is about the system rather than the intent.

## The traversal

The brief's "prove the traversal" step asks for one control. All four walk:

```
$ ./traverse.sh
profile: GRC Engineering Pipeline — controls in scope
  in scope: ac-3 au-3 cm-6 sc-28
...
control: sc-28
  resources:   aws_s3_bucket_server_side_encryption_configuration.primary, ...
  policy:      compliance.sc28_aws
  verified at: plan-time
  evidence:    https://raw.githubusercontent.com/.../evidence.tar.gz
  vault:       s3://grc-challenge-evidence-vault-.../evidence.tar.gz
  signer:      ^https://github.com/sevenbelowllc/.../grc-gate\.yml@refs/.*$

  integrity:    OK  (3dd2a1af...)
  authenticity: OK  (issuer=https://token.actions.githubusercontent.com)
  preservation: OK  (locked until 2026-07-28T02:09:29Z)
  CHAIN INTACT

TRAVERSAL COMPLETE — 4/4 control(s) walked from profile to verified evidence
```

Nothing about which controls exist, which bundle proves them, or who signed it
is hardcoded in the script. It fetches over the network from the published URL
rather than reading the working tree, because *"the file next to me verifies"*
is a much weaker claim than *"the file a stranger downloads verifies"*.

## In CI

[`grc-gate.yml`](../../.github/workflows/grc-gate.yml) now validates the
committed OSCAL on every pull request, converts that run's own verdicts into an
assessment-results document, and puts it in the run's signed evidence bundle.
Every pull request produces machine-readable evidence of its own control state.

## Cost

Free, except the vault. `terraform destroy` on
[`terraform/`](terraform/) fails until the last uploaded object's Object Lock
retention expires — 24 hours at the default. Pennies in the meantime; the
constraint is timing, not money.
