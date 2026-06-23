# Week 1 Submission — Your First Compliant Resource

## Writeup

This Terraform module provisions an S3 **data** bucket and a dedicated S3
**access-log** bucket that together satisfy five NIST 800-53 Rev 5 controls and
emit machine-readable proof of every one — no screenshots, no narrative, just
code and the evidence it generates.

- **SC-28 — Protection of Information at Rest.** AES-256 server-side encryption
  enabled by default on both buckets.
- **AC-3 — Access Enforcement.** All four S3 public-access-block flags
  (`block_public_acls`, `block_public_policy`, `ignore_public_acls`,
  `restrict_public_buckets`) set to `true` on both buckets — four independent doors.
- **CM-6 — Configuration Settings.** Object versioning on the data bucket (prior
  states recoverable and auditable), plus four mandatory tags — `Project`,
  `Environment`, `ManagedBy`, `ComplianceScope` — enforced for every taggable
  resource through the provider `default_tags` block so they can't be forgotten.
- **AU-3 / AU-6 — Audit Record Content / Review.** Server access logging from the
  data bucket to the dedicated log bucket, wired in the required order: object
  ownership controls → `log-delivery-write` ACL → logging configuration.

Proof is the committed `evidence/plan.json` (`terraform show -json`).
`terraform validate` passes and all five controls are present in the plan. The
SC-28 attestation is also surfaced as the `encryption_algorithm` output
(`AES256`) for a single machine-readable assertion of encryption-at-rest.

See `compliance-mapping.md` for the full crosswalk of these controls to CIS AWS
Benchmark, PCI-DSS, SOC 2, ISO 27001, and HIPAA.

## What this repo contains

| Path | Purpose |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf` | Starter skeleton (TODOs intact — controls are the exercise) |
| `solution/` | **Reference implementation** of all five controls + SC-28 output |
| `evidence/plan.json` | Machine-readable proof (`terraform show -json`) — week 2 reads this |
| `compliance-mapping.md` | NIST → CIS/PCI/SOC2/ISO/HIPAA control crosswalk |
| `verify.sh` | Post-apply live checks (encryption, versioning, public-access block) |

> The worked controls live in **`solution/`**, not the top-level `main.tf` (the
> top-level file is the starter, deliberately left with TODOs). Point reviewers at
> `solution/` and `evidence/plan.json`.

## How to verify

```bash
# 1. Configuration is valid
cd solution && terraform init -backend=false && terraform validate    # Success!

# 2. Evidence contains all five controls
jq -r '.resource_changes[] | "\(.change.actions[0])  \(.address)"' ../evidence/plan.json
#  -> SC-28 encryption rule (AES256), AC-3 four PAB flags true, CM-6 versioning
#     Enabled + four tags, AU-3/AU-6 logging block

# 3. (optional) live checks after an apply
./verify.sh    # shows AES256, versioning Enabled, all four public-access flags true
```

## Done when (from the brief)

- [x] `terraform validate` passes
- [x] `evidence/plan.json` contains all five controls (encryption rule, four-flag
      public access block, versioning enabled, four tags, logging target)
- [ ] *(optional)* `verify.sh` shows AES256 / Enabled / four flags true — only
      applies if you `terraform apply` the solution's data+log buckets

## How to submit

There is no upload portal or review queue. Submission, per the brief, is:

1. This public repo (you're looking at it).
2. A LinkedIn post tagging **GRC Engineering Club** with **`#GRCEngClubChallenge`**,
   stating one true thing that was harder than expected.

### LinkedIn post — draft (edit before posting; make the "harder than expected" line your own)

> Week 1 of the GRC Engineering Club challenge: I wrote Terraform for an S3
> bucket that satisfies five NIST 800-53 controls — SC-28 (encryption at rest),
> AC-3 (public access blocked on all four flags), CM-6 (versioning + enforced
> tags), and AU-3/AU-6 (access logging) — and emits the proof as JSON from
> `terraform plan`. No screenshots, no narrative; the evidence is the artifact.
>
> Harder than expected: the audit-logging control. On modern AWS you can't just
> turn logging on — the destination bucket needs object-ownership controls set
> *before* it will accept the `log-delivery-write` ACL, and only then will the
> logging config attach. Get the order wrong and you get AccessDenied. Naming a
> control is one skill; sequencing the resources that actually satisfy it is
> another.
>
> #GRCEngClubChallenge @GRC Engineering Club
