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

## 8. The verifier's own transcript gets none of the four properties

`verify-pipeline.sh` runs on every pull request as a required status check, and
its fourteen-check verdict is the artifact a reader is most likely to treat as
proof that everything else here works. It is also the least protected thing in
the build.

The job uploads the transcript with `actions/upload-artifact` and does nothing
further to it: no SHA-256 sidecar, no cosign signature, no Rekor entry, no
Object Lock — none of the four legs section 3 enumerates. It expires on GitHub's
artifact retention, which makes the record of the verification shorter-lived
than the vault objects it verifies. The copy committed at
[`evidence/pipeline-verification.txt`](evidence/pipeline-verification.txt) is a
hand-run capture that predates the CI job, so the most-cited transcript in the
repository is also its least machine-attested.

This is a deliberate trade rather than an oversight. The verifying job's role
has a read-only identity policy precisely so that the thing checking the vault
cannot write to it. Signing and depositing the transcript from that job would
grant the verifier write access to the evidence it verifies — buying
preservation by spending separation of duties, which is the wrong direction.

**What would close it:** a separate job with its own narrowly-scoped role that
signs and deposits the transcript after the verifying job finishes, so the
identity producing the record is not the identity auditing the vault.

## 9. The timeliness leg rents infrastructure it does not operate

Keyless signing needs two hosted services: Fulcio issues the ten-minute
certificate, and Rekor records the signature. Both are the **Sigstore public
good instance**, operated by the OpenSSF with volunteer on-call engineers from
member companies, targeting a **99.5% availability SLO**. That is an objective,
not an agreement — roughly three and a half hours of permitted monthly downtime,
no contractual remedy, and no support relationship, because nothing is being
paid for.

The consequence is concrete in both directions. At signing time, if Fulcio or
Rekor is unavailable the gate's signing step fails and the required check fails
with it, so this pipeline's availability is bounded by a service the project
neither operates nor pays for. At verification time, the ten-minute certificate
is long expired; only Rekor's countersignature makes it verifiable at all. If
the public instance were retired, existing bundles would lose the leg that
currently rescues them.

The apparent redundancy is not redundancy. Each bundle carries a Rekor entry
*and* an RFC 3161 timestamp token, which reads as two independent sources of
time. Decoding the token shows the issuer is `sigstore.dev`'s
`sigstore-tsa-selfsigned` authority, stamped in the same second as the log
entry. Two mechanisms, one operator, one trust root, one outage domain. Counting
them as two would be exactly the kind of double-counting section 3 exists to
prevent.

There is a second-order effect worth stating plainly rather than discovering
later: a transparency log is public by design, so every signature here
permanently publishes the repository, the workflow path, the ref, and the
timestamp. That is correct and intended for a public repository built to be
verified by strangers. It is a real disclosure decision before the same pattern
is applied to private work.

**What would close it:** a self-hosted Sigstore deployment, or a countersignature
from a commercially operated timestamp authority under a contract, so the
timeliness claim survives one operator disappearing. Both cost money, which is
the honest trade being made here — the four legs are free precisely because one
of them is somebody else's donated infrastructure.

## 10. The plan the gate reads is generated against no account

`verify-pipeline.sh` regenerates the Terraform plan from source on every run and
evaluates the policies against that, rather than against the committed
`plan.json`. That closes a real hole — for a while, editing `main.tf` to remove
the public access block left every required check green, because `terraform
validate` only parses and type-checks and conftest re-read a fixture generated
by hand in July. It does not close as much as it looks like it closes.

The regenerated plan is produced in a temp copy with
`skip_credentials_validation`, `skip_requesting_account_id`,
`skip_metadata_api_check` and `skip_region_validation` all set, pointed at
placeholder credentials. That is what makes the check runnable by a stranger
with no AWS account, which is the property the whole repository is built around.
The cost is that the plan is a plan against **nothing**. Terraform is not asking
any account whether this would work.

So the check proves:

> *The committed source, evaluated in isolation, describes infrastructure that
> satisfies the three plan-time controls.*

and not:

> *Applying this source to the target account would succeed, or would produce
> those resources.*

Everything an account would have objected to is invisible here: a bucket name
already taken, a service control policy or permission boundary that forbids the
call, a region where something is not offered, a quota. Those surface at
`terraform apply` and this check will have said PASS.

This is narrower than limit 1 and stacks on top of it. Limit 1 is that a plan is
an intention rather than a running resource. This one is that the intention is
being checked against an empty room.

**What would close it:** the `grc-gate-oidc` job already generates the plan with
real read-only credentials through GitHub OIDC, which does exercise account-side
validation. It is currently **not** in the required status check set, so it can
fail without blocking a merge. Requiring it would make the credentialed plan
load-bearing; the trade is that the gate then depends on the AWS role existing
and the OIDC trust holding, which is why the credential-free check is the one
wired into `verify-pipeline.sh`.

---

## Why write this down

An assessor's first question about any automated control is "what does it miss?"
Answering it before they ask converts the conversation from an interrogation
into a review, and the answer is the same either way — the only variable is
whether it came from the person who built the thing or from the person auditing
it.

There is also a cheaper reason. Every limit above is a piece of work someone
would otherwise have to rediscover, including the author in six months.
