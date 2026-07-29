# What this pipeline does not prove

A control mapping that claims everything it brushes against is a wish list. The
same is true of a pipeline. This page is the list of things a reader could
reasonably infer from the six weeks of work that would be **wrong**, written
down deliberately, because the difference between a compliance engineer and a
compliance theatre is whether the gaps are documented or discovered.

Every limit here is real and currently unaddressed. Several have obvious fixes;
those are named. None of them are secretly fine.

---

## 1. Plan-time is not runtime

Three of the four controls — SC-28, AC-3, CM-6 — are enforced by evaluating a
**Terraform plan**. That is genuinely strong: a pull request that would remove
bucket encryption fails the gate and cannot merge, so the violation never
reaches the account at all. Prevention beats detection.

But it is entirely a claim about **intent**. The gate proves that Terraform
*said it would* create an encryption configuration. It does not prove that
`terraform apply` ran, that it succeeded, or that the resource still exists an
hour later.

The pipeline therefore proves:

> *No merged change to this repository intends to violate these three controls.*

and not:

> *These three controls are in force in the AWS account right now.*

Those are different sentences and the second one is the one an auditor cares
about. Week 5's Security Hub findings partially close the gap for the applied
account, and AU-3's evidence is runtime output specifically because plan-time
would have proven nothing — but the closure is partial and per-control, not
systematic.

**What would close it:** running the same Rego rules against `terraform show
-json` of live state on a schedule, or against AWS Config's resource
configuration items, and treating a divergence between plan-time and runtime
verdicts as its own finding.

## 2. Drift is mostly invisible

The pipeline watches the **repository**, not the account. A change made in the
AWS console, by a script, by another Terraform workspace, or by an incident
responder at 3am is not evaluated by any rule here.

Two partial mitigations exist and neither is a control:

- **Security Hub** (week 5) surfaces findings against its own standards, which
  overlap the four controls unevenly — it will notice a public bucket, but it
  has no opinion about the four required tags.
- **CloudTrail** (week 5) records that the change happened, so it is
  *forensically* recoverable. Being able to reconstruct who broke a control last
  Tuesday is worth a great deal and is not the same as the control holding.

**What would close it:** AWS Config rules derived from the same Rego source, so
the runtime check and the plan-time check cannot disagree by accident, with
drift raised as a POA&M item in OSCAL rather than as a dashboard tile.

## 3. The evidence chain is only as long as it looks

Week 4's four legs — integrity, authenticity, timeliness, preservation — each
prove exactly one thing, and it is worth being precise about which:

| Leg | Mechanism | Proves | Does **not** prove |
|---|---|---|---|
| Integrity | SHA-256 sidecar | The bytes are unmodified since the hash was written | That the bytes were correct when hashed |
| Authenticity | cosign keyless signature | A specific identity signed these bytes | That the identity was honest, or the content true |
| Timeliness | Rekor transparency log | The signature existed at a specific time | That the *evidence* was collected at that time |
| Preservation | S3 Object Lock COMPLIANCE | The object cannot be deleted before its retention expires | That it was ever uploaded — an absent object has no lock |

The last column matters. A signed bundle proves provenance, not accuracy: if
`terraform plan` had produced a wrong answer, the pipeline would have signed the
wrong answer, faithfully, and every verification would still pass. **The chain
proves nobody tampered with the evidence. It does not prove the evidence is
right.** That is a property of the tools that generated it, and it is inherited
rather than established.

The preservation leg has a subtler gap: nothing here detects an evidence bundle
that was never vaulted at all. Object Lock stops deletion; it does not create a
record of an expected object that never arrived.

**What would close it:** an expected-artifact manifest checked against the vault
on a schedule, so a missing deposit is as loud as a modified one.

## 4. Thirty days of Object Lock is a demo value, not a retention policy

The vault is configured with `vault_retention_days = 30`. COMPLIANCE mode means
those days are real — the objects genuinely cannot be deleted by anyone, including
the account root, and [the proof is
committed](evidence/vault-preservation-proof.txt): a hard delete attempted with
admin credentials returned *"Access Denied because object protected by object
lock."*

But real records-retention regulation is measured in years, not weeks. SEC
17a-4(f), FINRA 4511(c) and CFTC 1.31(c) each require a retention *period*, a
*designated third party* who can produce records if the firm cannot, and an
audited process around both. Object Lock is one of those three things.

The number is set by what the CI verifier needs, not by a regulation: the
pipeline checks on every pull request that retention is still in the future,
and a one-day lock would make that check red for calendar reasons. It was one day
while the demonstration had to be torn down inside the challenge window.
Changing the number is a one-line edit; satisfying the regulation is not.
Saying otherwise would be exactly the kind of claim this whole build exists to
make unnecessary.

See [week-4's deep dive](../week-4/worm-vs-iam-preservation-deep-dive.md) for
why a deny-delete IAM policy is not a substitute.

## 5. Scope is four controls of a thousand-odd

The profile selects SC-28, AC-3, AU-3 and CM-6. NIST 800-53 Rev 5 has over a
thousand controls and enhancements. This is a demonstration of a *method*, not a
compliant system, and the profile says so by refusing to pad.

Controls the build genuinely touches but does not claim — AU-9 from versioning
the log bucket, AU-10 from CloudTrail log-file validation, SI-4 from Security
Hub, CP-9 from cross-region replication — are deliberately excluded. Each would
need its own evidence and its own gate to be worth an entry, and a profile that
lists controls it cannot prove devalues the ones it can.

## 6. The assessment is of a component, not a system

OSCAL's assessment model expects a System Security Plan: an authorization
boundary, a system owner, a FIPS-199 categorisation, an inventory. This build
has none of those, because the thing being assessed is a reusable pipeline, not
an authorized system.

The assessment plan's `import-ssp` therefore points at a back-matter resource
for the component definition, with remarks saying exactly that. A reader should
not infer an authorization boundary from the presence of an assessment plan.

## 7. Signing identities are not equivalent

Week 4's evidence was signed by the CI workflow's OIDC identity — a machine, in
a repository, under branch protection. Week 5's was signed from a workstation
with a personal Google identity.

Both verify. They are not the same strength of claim. A workflow identity binds
the signature to a reviewed, logged, reproducible process; a personal identity
binds it to whoever was at the keyboard. Where evidence is captured against a
live account it is currently the second kind, and the pipeline does not
distinguish them anywhere except in the `evidence-signer-identity` prop that
`traverse.sh` reads.

**What would close it:** capturing runtime evidence from a scheduled workflow
rather than by hand, so every signature in the chain is a workflow signature.

---

## Why write this down

An assessor's first question about any automated control is "what does it miss?"
Answering it before they ask converts the conversation from an interrogation
into a review, and the answer is the same either way — the only variable is
whether it came from the person who built the thing or from the person auditing
it.

There is also a cheaper reason. Every limit above is a piece of work someone
would otherwise have to rediscover, including the author in six months.
