# A GRC Engineering Pipeline, Built in Public

**David Kramer** · SevenBelow LLC · July 2026
Repo: [github.com/sevenbelowllc/grc-engineering-club](https://github.com/sevenbelowllc/grc-engineering-club)

---

## The one-sentence version

I built a pipeline that takes an AWS resource from *"it works"* to *"a stranger
can verify it satisfies NIST 800-53 without talking to me"* — and every claim on
this page is checkable by running a command.

```bash
git clone https://github.com/sevenbelowllc/grc-engineering-club
cd grc-engineering-club && ./verify-pipeline.sh
```

Latest run: **12 checks, 12 passed, 0 skipped**
([transcript](evidence/pipeline-verification.txt)) — the two vault checks need
AWS credentials for the evidence account and report `skipped` without them,
which is the honest verdict rather than a pass.

---

## What it does

Six stages, built one per week, that together close the loop from infrastructure
code to an auditor's document format:

| Stage | What it does | The thing that makes it real |
|---|---|---|
| **1 · Provision** | Terraform baseline satisfying SC-28, AC-3, CM-6 | Provider `default_tags` makes the tagging control impossible to forget on a new resource |
| **2 · Express** | Rego policies that read a Terraform plan | Rules match **by reference, not by value** — the bucket's name doesn't exist yet |
| **3 · Enforce** | GitHub Actions gate, required status check | A violation never reaches the account, because the merge is blocked |
| **4 · Prove** | SHA-256 + keyless cosign + Rekor + S3 Object Lock | Four separate properties, four separate mechanisms |
| **5 · Observe** | CloudTrail, Security Hub, cross-region replication | The *running* account, which is a different claim from the plan's intent |
| **6 · Publish** | OSCAL profile, component, assessment plan and results | An assessor follows links instead of scheduling a call |

The whole thing runs on keyless GitHub OIDC. There are no stored AWS
credentials anywhere in the repository or its secrets.

---

## Proof

Evidence over adjectives. Every row is a link to something that ran.

| Claim | Proof |
|---|---|
| The policies are unit-tested | [`opa test policies/ -v` → **PASS: 6/6**](../week-2/evidence/opa-test.txt) |
| A compliant change merges | [**PR #3** — green run, all three namespaces pass](https://github.com/sevenbelowllc/grc-engineering-club/pull/3) |
| A non-compliant change **cannot** merge | [**PR #7** — SC-28 denies both buckets, exit 1, merge blocked](https://github.com/sevenbelowllc/grc-engineering-club/pull/7) |
| Evidence survives the failure | The red run still signed and uploaded its bundle — `if: always()` in [`grc-gate.yml`](../../.github/workflows/grc-gate.yml) |
| The evidence is intact, authentic and timely | [`verify-evidence.sh` → **CHAIN INTACT**](../week-4/evidence/ci-verify-pass.txt), signed by the workflow in [PR #9](https://github.com/sevenbelowllc/grc-engineering-club/pull/9) |
| Tampering is detected | [The same script on a modified bundle → **FAIL**](../week-4/evidence/ci-verify-tamper-fail.txt) |
| The evidence cannot be deleted | [Hard delete with **admin** credentials → *"Access Denied because object protected by object lock"*](evidence/vault-preservation-proof.txt) |
| The OSCAL is schema-valid | `trestle validate -a` → **5 documents VALID** ([in the transcript](evidence/pipeline-verification.txt)) |
| An assessor can traverse it | [`./traverse.sh` → **4/4 controls** walked from profile to verified evidence](evidence/chain-intact-four-legs.txt) |
| The converter fails when it should | [Three guard cases, exit 3, nothing written](evidence/converter-guards.txt) |
| The verifier itself is gated | `verify-pipeline` is a **required status check** on `main` — [run 30422410397](https://github.com/sevenbelowllc/grc-engineering-club/actions/runs/30422410397) passed 12/12 with zero skips, against live AWS |

---

## Three decisions worth stealing

### 1. Match by reference, not by value

The obvious way to write "every bucket must be encrypted" is to compare the
encryption resource's `bucket` field to the bucket's name. It does not work. At
plan time the bucket name is `grc-challenge-dev-data-${random_id.suffix.hex}` —
a value that does not exist yet. A name-matching rule cannot evaluate the plan at
all, so it silently passes.

The plan does contain something stable: `configuration.root_module.resources[]
.expressions.bucket.references`, which records the *symbolic address*
`aws_s3_bucket.primary.id`. Matching on that works before apply, works at any
module depth, and works regardless of what the resource ends up being called.

```rego
deny contains msg if {
    some bucket in config_resources
    bucket.type == "aws_s3_bucket"
    not encryption_references(sprintf("aws_s3_bucket.%s", [bucket.name]))
    msg := sprintf("SC-28: aws_s3_bucket '%s' has no matching server-side encryption configuration...", [bucket.name])
}
```

The general lesson: **policy-as-code that runs before apply has to reason about
intent, not state.** Most examples on the internet quietly assume otherwise.

### 2. The control mapping lives in the OSCAL, not in the converter

Week 6's headline piece is
[`oscal-from-conftest.py`](oscal-from-conftest.py), which turns

```json
{ "namespace": "compliance.sc28_aws", "successes": 1 }
```

into

```json
{ "target-id": "sc-28_obj", "status": { "state": "satisfied" } }
```

The tempting design is a dictionary in the converter mapping package names to
control IDs. I deliberately didn't. That mapping lives in the component
definition as a `policy-package` prop on each `implemented-requirement`, because
that is the document whose *job* is to say how a control is implemented, and the
converter reads it back out at conversion time.

The result is that a converter with a stale mapping is not possible: there is no
second copy to go stale. Rename a Rego package without updating the component and
the build fails rather than silently dropping a control.

**A hardcoded table would have been a third place the truth lives, and the third
place is always the one nobody updates.**

### 3. An absent verdict is not a passing verdict

The guard I'm proudest of runs in the direction nobody checks. The converter
verifies that every policy package the component *claims* gates a control
actually appears in the conftest output:

```
mapping error: the component definition claims these policy packages gate a
control, but conftest reported no result for them:
  compliance.sc28_aws  (control sc-28)
An absent verdict is not a passing verdict.
```

Here is the failure it prevents. A policy file gets renamed, moved, or picks up a
syntax error that makes it stop loading. Conftest returns one fewer entry and
**exit code 0**. The gate is green. The assessment-results document is valid. It
simply no longer mentions SC-28 — and nothing anywhere turns red.

That is how automated compliance rots: not with a failure, but with a silence.
Checking for the silence costs eight lines.

The same principle earned its keep a second time, in an unrelated subsystem.
`verify-pipeline.sh` exits `0` when checks are *skipped* — right for a laptop
with a partial toolchain, wrong for CI, where a skip means an install step
broke. A CI job that trusted the exit code alone would go green having run six
checks instead of twelve. So the job parses the summary line and fails the build
on a non-zero skip count. Two guards, two subsystems, one failure mode: a green
signal that quietly covers less than it appears to.

---

## What I would build next

The pipeline proves controls for **one account that already exists**. The
interesting problem is the one before that: standing up a client's foundation so
these controls are true from the first `apply`.

Concretely — an interactively-bootstrapped AWS Organizations landing zone.
Admin / NonProd / Prod accounts, OUs and SCPs, an org-level CloudTrail, a Config
aggregator, Security Hub and GuardDuty enabled at the org, Identity Center, and
Terraform state bootstrapped before any of it — driven by a single idempotent
shell script an engineer runs once per client.

I scoped it during this challenge and **deliberately did not build it**, for
three reasons worth stating because the reasoning is the point:

1. **It would orphan the evidence.** Weeks 1–5 evidence — the signed bundle, the
   plan, twelve Security Hub findings, a 53-object replica listing — was captured
   against a single-account topology. Rebuilding as multi-account invalidates all
   of it and re-proves controls that are already proven. The challenge scores
   control mapping and evidence quality, not account topology.
2. **The iteration loop is irreversible.** Closing an AWS member account triggers
   a 90-day suspended state; root email addresses must be globally unique across
   all of AWS and cannot be reused on a retry; an organization with member
   accounts cannot be deleted. Every test run burns addresses and leaves 90-day
   residue. Nothing like the S3 teardown loop I used all six weeks.
3. **It is 40–80 hours to a client-ready standard.** There were five days.

Knowing which work *not* to start is most of the job.

The narrower things I'd do first, in order: run the same Rego rules against live
state on a schedule so plan-time and runtime verdicts can be compared; generate
AWS Config rules from the same Rego source so the two checks cannot disagree by
accident; and capture runtime evidence from a scheduled workflow rather than by
hand, so every signature in the chain is a workflow signature rather than a
person's.

---

## What actually clicked

**Compliance evidence is a supply-chain problem, and the tooling already
exists.** Cosign, Rekor and Object Lock were built for artifacts, not audits, but
the four properties they give you — integrity, authenticity, timeliness,
preservation — are exactly the four an auditor is trying to establish about a
screenshot, and are the four a screenshot cannot provide.

The realisation that reframed the rest: **those four are separate properties
needing separate mechanisms.** A hash proves the bytes didn't change; it says
nothing about who produced them. A signature proves who; it says nothing about
when. Rekor proves when; it does nothing to stop deletion. Object Lock stops
deletion; it proves nothing about content. Compliance programmes routinely
collapse all four into "we have evidence," and then discover during an audit
which one they were actually missing.

**And the second thing: a blocked merge beats a caught mistake.** Detection is
the industry's default posture, and it is a posture of permanent lateness —
every finding is a thing that already happened. Moving the same rule from
"monitor" to "required status check" changes what it *is*. The violation stops
being an incident and starts being a build error, which nobody escalates,
nobody writes a ticket for, and nobody has to explain to an auditor.

The argument applies to the verification as much as to the controls. The
twelve-check verdict this page opens with used to be something I remembered to
run; it now runs on every pull request and is itself a required status check
alongside the gate. The check that proves the pipeline works is no longer
allowed to be the one nobody ran.

---

## What this does *not* prove

Seven limits, written down deliberately:
[**ASSURANCE-BOUNDARY.md**](ASSURANCE-BOUNDARY.md).

The short version — plan-time is not runtime; drift made outside Terraform is
mostly invisible; the chain proves nobody tampered with the evidence but not
that the evidence is *correct*; and thirty days of Object Lock is a demo value,
not a retention policy.

An assessor's first question about any automated control is "what does it miss?"
The answer is the same whoever produces it. The only variable is whether it came
from the builder or the auditor.

---

## Try it

```bash
git clone https://github.com/sevenbelowllc/grc-engineering-club
cd grc-engineering-club

./verify-pipeline.sh    # every eligibility check, one verdict
./traverse.sh           # profile → component → evidence → CHAIN INTACT
```

No AWS account required. No cooperation from me required. That was the point.
