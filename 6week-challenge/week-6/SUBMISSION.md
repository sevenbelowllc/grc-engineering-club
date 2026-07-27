# Week 6 Submission — Speak the Auditor's Language

## Writeup

Five weeks produced proof in engineering formats: Terraform plans, Rego rules, a
JSON verdict file, signed tarballs. All of it real, none of it in a shape an
assessor can consume. This week builds the bridge, and then proves the bridge
holds by walking across it.

Two documents were asked for. I shipped five, because two of the extras turned
out to be the interesting part:

| Document | What it says |
|---|---|
| **profile** | The claim. Four control IDs from NIST 800-53 Rev 5 — `ac-3`, `au-3`, `cm-6`, `sc-28` — and nothing else |
| **component definition** | How each is implemented: the Terraform resource, the Rego package, the evidence, the signer |
| **assessment plan** | What gets assessed and by which method. Required by OSCAL; useful for a reason I did not expect |
| **assessment results** ×2 | The verdicts. One from the real signed gate run, one negative control |

All five `trestle validate` clean against OSCAL 1.2.1. All four controls walk end
to end from the profile to a verified evidence bundle.

The brief asks you to prove the traversal for one control. All four traverse:

```
$ ./traverse.sh
TRAVERSAL COMPLETE — 4/4 control(s) walked from profile to verified evidence
```

## The lesson: the mapping belongs in the document, not the tool

The centrepiece is [`oscal-from-conftest.py`](oscal-from-conftest.py), which
converts

```json
{ "namespace": "compliance.sc28_aws", "successes": 1 }
```

into

```json
{ "target-id": "sc-28_obj", "status": { "state": "satisfied" } }
```

Somebody has to carry that verdict across. If it is a person, they redo it every
time the gate runs, and the day they stop, the mapping silently goes stale.

The obvious implementation is a dictionary in the converter mapping Rego package
names to control IDs. I deliberately did not write one. **The mapping lives in
the component definition**, as a `policy-package` prop on each
`implemented-requirement`, because that is the document whose job is to say how a
control is implemented. The converter reads it back out at conversion time:

```python
# read_control_mapping() — the entire mapping logic
packages = [p["value"] for p in req.get("props", [])
            if p.get("name") == "policy-package"]
```

Add a control to the component definition and its verdicts start converting, with
no change to the converter. Rename a Rego package without updating the component
and the build fails instead of quietly dropping a control. The converter *cannot*
claim a control the component does not implement, because it has no independent
source for the list.

A hardcoded table would have been a third place the truth lives, and the third
place is always the one nobody updates.

## The guard I am proudest of: an absent verdict is not a passing verdict

The converter checks both directions and exits `3` with nothing written:

**Forward** — conftest reported on a package no requirement claims. A control is
being gated and the assurance is going nowhere.

**Reverse** — the component claims a package gates a control, and conftest
returned no result for it:

```
mapping error: the component definition claims these policy packages gate a
control, but conftest reported no result for them:
  compliance.sc28_aws  (control sc-28)
An absent verdict is not a passing verdict. Either the gate did not run the
policy, or the component definition is claiming a rule that no longer exists.
```

The reverse one is the one that would have bitten. A policy file gets renamed,
moved, or picks up a syntax error that stops it loading. Conftest returns one
fewer entry and **exit code 0**. Gate green. Generated document schema-valid. It
simply no longer mentions SC-28 — and nothing, anywhere, turns red.

That is how automated compliance rots: not with a failure, with a silence.
Checking for the silence cost eight lines.

Transcript of all three cases plus the determinism check:
[`evidence/converter-guards.txt`](evidence/converter-guards.txt).

## The control I refused to automate

Three of the four controls are enforced at plan time. **AU-3 has no Rego rule,
deliberately, and its `remarks` field says so at length.**

A Terraform plan can show a CloudTrail trail *will be created* with the right
arguments. It cannot show the trail is *delivering records*, because delivery is
a runtime property of a system that does not exist yet at plan time. A plan-time
rule for AU-3 would have produced a fourth green check attesting to nothing —
and a green check that attests to nothing is worth less than an honest gap,
because it spends credibility instead of earning it.

So AU-3's evidence is captured `get-trail-status` output showing `IsLogging: true`
with recent log and digest delivery. Narrower than the plan-time claims (true of
one moment, not of every future PR) and stronger (about the system, not the
intent).

The assessment plan states this in the model rather than in a footnote: two
`control-selections`, one per method. The difference between them *is* the
assurance boundary of the pipeline.

## Reproducible output, which OSCAL makes awkward

Running the converter twice on the same input produces **byte-identical** JSON,
so a reviewer can regenerate the committed document and `diff` it.

That needed a workaround. OSCAL's `uuid` datatype pins the version nibble to `4`
— the regex is literally `[4][0-9A-Fa-f]{3}` — which rules out `uuid5`, the
obvious tool for deriving an identifier from a name. So the UUIDs are SHA-256
derived with the version and variant bits then set to what v4 carries. They are
hash-derived identifiers wearing v4's syntax, and the docstring says so plainly
rather than letting a reader assume randomness.

The assessment timestamp is an input rather than `now()` for the same reason, and
it is not asserted by hand. The `grc-gate-run` document is stamped
`2026-07-22T01:16:40+00:00` — the `integratedTime` of the Rekor transparency-log
entry countersigning that evidence bundle:

```bash
python3 -c 'import json,datetime;b=json.load(open("../week-4/evidence/evidence.tar.gz.sig.bundle"));
e=b["verificationMaterial"]["tlogEntries"][0];
print(datetime.datetime.fromtimestamp(int(e["integratedTime"]),datetime.timezone.utc))'
# 2026-07-22 01:16:40+00:00
```

The "when" of the assessment comes from a public append-only log run by somebody
else, not from my clock.

## Where OSCAL does not fit, said out loud

`import-ssp` is required on an assessment plan. This build has no System Security
Plan, because the subject is a reusable pipeline component, not an authorization
boundary with a system owner and a FIPS-199 categorisation.

Inventing a thin SSP to satisfy the field would have been worse than admitting
it. The reference resolves to a back-matter resource for the component
definition, and the `remarks` state exactly what is and is not being claimed. A
reader should not infer an authorization boundary from the presence of an
assessment plan.

## The negative control

The same converter, run against [`week-3/plan-broken.json`](../week-3/plan-broken.json)
— a plan with the encryption resources removed — emits `not-satisfied` for SC-28.
It is committed as
[`assessment-results/broken-plan-negative-control/`](oscal/assessment-results/broken-plan-negative-control/assessment-results.json)
and labelled as a negative control in its own metadata so nobody mistakes it for
a production verdict.

A pipeline that has only ever produced passing results has not been shown to be
*capable* of producing a failing one. That is the difference between a control
and a decoration.

## Evidence index

| File | What it shows |
|---|---|
| [`evidence/pipeline-verification.txt`](evidence/pipeline-verification.txt) | `./verify-pipeline.sh` — 12 checks, 12 passed, 0 skipped |
| [`evidence/chain-intact-four-legs.txt`](evidence/chain-intact-four-legs.txt) | All four legs green: integrity, authenticity, timeliness, preservation |
| [`evidence/vault-preservation-proof.txt`](evidence/vault-preservation-proof.txt) | COMPLIANCE Object Lock config, retention, and a hard delete refused with **admin** credentials |
| [`evidence/converter-guards.txt`](evidence/converter-guards.txt) | The denying gate, both mapping guards, and the determinism diff |
| [`evidence/conftest-results-broken-plan.json`](evidence/conftest-results-broken-plan.json) | Raw conftest output the negative control was generated from |
| [`oscal/`](oscal/) | The five documents |

## Control mapping

| Control | Terraform resource | Rego package | Verified at | Evidence |
|---|---|---|---|---|
| **SC-28** | `aws_s3_bucket_server_side_encryption_configuration` | `compliance.sc28_aws` | plan-time | week-4 bundle + vault |
| **AC-3** | `aws_s3_bucket_public_access_block` | `compliance.ac3_aws` | plan-time | week-4 bundle + vault |
| **CM-6** | provider `default_tags` + `aws_s3_bucket_versioning` | `compliance.cm6_aws` | plan-time | week-4 bundle + vault |
| **AU-3** | `aws_cloudtrail.this` | — *none, deliberately* | runtime | week-5 bundle + vault |

Each control links its evidence **twice**: a `raw.githubusercontent` copy anyone
can fetch without credentials, and an `s3://` copy under Object Lock that nobody
can delete. A public copy proves the evidence is reachable but not that it
survived; a locked copy proves it survived but is unreadable to the assessor.
Both, or the claim is weaker than it looks.

## Done when — checklist

- [x] `trestle validate` returns `VALID` for the component and the profile
      *(and for the assessment plan and both assessment-results — 5/5)*
- [x] At least one evidence link resolves to a real signed bundle and prints
      `CHAIN INTACT` *(all four do, with all four legs green)*
- [x] Every `href` in the documents verified to resolve — 13/13 HTTP links `200`
- [x] The case study is written: [`PORTFOLIO-CASE-STUDY.md`](PORTFOLIO-CASE-STUDY.md)
- [x] The full pipeline passes end to end: `terraform validate`, `conftest`,
      `trestle validate`, `cosign verify`, vault preservation — 12/12
- [x] What the pipeline does **not** prove is written down:
      [`ASSURANCE-BOUNDARY.md`](ASSURANCE-BOUNDARY.md)
- [ ] OSCAL documents signed — [`sign-oscal.sh`](sign-oscal.sh) is written and
      validated; cosign keyless needs an interactive browser sign-in
- [ ] Vault upload proven in a CI run — needs the `AWS_GATE_ROLE_ARN` and
      `EVIDENCE_VAULT_BUCKET` repository variables set
- [ ] Case study published to the portfolio site
