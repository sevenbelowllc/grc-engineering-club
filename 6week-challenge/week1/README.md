# Week 1: Your First Compliant Resource

A Terraform module that provisions an S3 **data** bucket and a dedicated S3
**access-log** bucket satisfying five NIST 800-53 Rev 5 controls, and emits
machine-readable proof of each — no screenshots, just code and the evidence it
generates.

The worked implementation lives in **[`solution/`](solution/)**. Point reviewers
there and at [`evidence/plan.json`](evidence/plan.json).

## Controls

- **SC-28** — server-side encryption (AES256) at rest on both buckets
- **AC-3** — all four S3 public-access-block flags `true` on both buckets
- **CM-6** — object versioning on the data bucket + four mandatory tags
  (`Project`, `Environment`, `ManagedBy`, `ComplianceScope`) via provider
  `default_tags`
- **AU-3 / AU-6** — server access logging to the dedicated log bucket, wired in
  the required order: ownership controls → `log-delivery-write` ACL → logging

## Verify

```bash
cd solution
terraform init
terraform validate          # Success!
terraform plan -out tfplan
terraform show -json tfplan > ../evidence/plan.json

# evidence contains all five controls:
jq -r '.resource_changes[] | "\(.change.actions[0])  \(.address)"' ../evidence/plan.json
```

## Layout

- [`solution/`](solution/) — the module implementing all five controls (local backend)
- [`evidence/plan.json`](evidence/plan.json) — machine-readable proof (`terraform show -json`)
- [`compliance-mapping.md`](compliance-mapping.md) — NIST → CIS/PCI/SOC2/ISO/HIPAA crosswalk
- [`SUBMISSION.md`](SUBMISSION.md) — writeup and submission notes
- `verify.sh` — post-apply live checks (encryption, versioning, public-access block)
