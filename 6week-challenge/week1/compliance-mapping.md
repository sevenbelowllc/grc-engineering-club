# Week 1 — Control-to-Infrastructure Mapping

Maps each NIST 800-53 (Rev 5) control in this module to the Terraform AWS
resource that implements it, the evidence that proves it, and the equivalent
criteria in other compliance frameworks.

**Authoritative labels:** the control IDs in the "Assignment control" column are
the contract the rest of the pipeline depends on (week 2 reads `evidence/plan.json`
and gates on these). Do **not** rename them in evidence. The "Precise 800-53 note"
column is GRC-accuracy commentary for the portfolio writeup, not a re-label.

## Control matrix

| Assignment control | Resource(s) | What it enforces | Precise 800-53 note | Evidence |
|---|---|---|---|---|
| **SC-28** — Protection of Information at Rest | `aws_s3_bucket_server_side_encryption_configuration` on **both** buckets (AES-256) | Default server-side encryption at rest | Clean fit. SC-28(1) if/when KMS-managed keys are used. | `plan.json` encryption rule; SC-28 attestation output (algorithm in effect) |
| **AC-3** — Access Enforcement | `aws_s3_bucket_public_access_block` on **both** buckets, all four flags `true` | Blocks public exposure on all four vectors | Fit. AC-6 (least privilege) and SC-7 (boundary protection) are secondary mappings. | `plan.json` four flags all true: `block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets` |
| **CM-6 (part 1)** — Configuration Settings | `aws_s3_bucket_versioning` on the **primary** | Prior object states recoverable/auditable | **Imprecise but assignment-intentional.** Versioning is data durability/integrity; **CP-9** (System Backup) or **SI-12** (Information Management & Retention) is the tighter control. Kept as CM-6 per assignment. | `plan.json` versioning `Enabled`; `verify.sh` shows `Enabled` |
| **CM-6 (part 2)** — Configuration Settings | provider `default_tags` block → `Project`, `Environment`, `ManagedBy`, `ComplianceScope` on every taggable resource | Enforced baseline metadata, can't forget on new resources | Good fit for CM-6. Also maps to ISO A.5.9 (asset inventory) via `ComplianceScope`. Implemented in `solution/main.tf` (`default_tags`). | `plan.json` four tags present on each resource |
| **AU-3 + AU-6** — Content of Audit Records / Audit Review | `aws_s3_bucket_ownership_controls` + `aws_s3_bucket_acl` (`log-delivery-write`) on the **log** bucket, then `aws_s3_bucket_logging` on the **primary** pointing at it | Captures S3 access logs to a dedicated, protected log bucket | **Split is more precise:** enabling capture = **AU-2** (Event Logging) + **AU-12** (Audit Record Generation); protecting the log bucket (ownership + ACL) = **AU-9** (Protection of Audit Information). **AU-6** (review/analysis) is an operational/process control the infra *enables* but does not by itself satisfy. AU-3 governs record *fields*, which S3 sets, not you. | `plan.json` logging block on primary; `verify.sh` confirms logging target |

## Cross-framework crosswalk

Exact CIS decimal numbering shifts between benchmark versions; names + AWS Config
rule IDs are the stable, machine-checkable anchors.

| Control | CIS AWS Foundations v3 | PCI-DSS v4.0 | SOC 2 (TSC) | ISO 27001:2022 | HIPAA Security Rule | AWS Config rule |
|---|---|---|---|---|---|---|
| **SC-28** (encryption) | §2.1.x "encryption-at-rest" | 3.5 / 3.5.1 | CC6.1, CC6.7 | A.8.24 | §164.312(a)(2)(iv) | `s3-bucket-server-side-encryption-enabled` |
| **AC-3** (public access block) | §2.1.x block public + account-level | 1.x, 7.x | CC6.1, CC6.6 | A.5.15, A.8.3 | §164.312(a)(1) | `s3-account-level-public-access-blocks`, `s3-bucket-public-read/write-prohibited` |
| **CM-6 p1** (versioning) | — (no standalone S3 control in v3) | 3.x retention; 10.5.x (for logs) | A1.2, CC7.x | A.8.13 (backup) | §164.312(c)(1) integrity | `s3-bucket-versioning-enabled` |
| **CM-6 p2** (tags) | — (governance, not a numbered S3 check) | 12.5.x asset inventory | CC6.1, CC3.x | A.5.9 (asset inventory) | §164.308(a)(1) | tag policies / `required-tags` |
| **AU-3/AU-6** (logging) | §3.x access logging | 10.2, 10.3 (content) | CC7.2, CC7.3 | A.8.15 (logging) | §164.312(b) audit controls | `s3-bucket-logging-enabled` |

## Evidence pipeline

- **Primary evidence:** `evidence/plan.json` from `terraform plan` — must contain the
  encryption rule (SC-28), four-flag public access block all true (AC-3), versioning
  enabled (CM-6 p1), four tags (CM-6 p2), and the logging target (AU-3/AU-6).
- **Live checks (if applied):** `verify.sh` confirms `AES256`, versioning `Enabled`,
  and all four public-access flags true.
- **SC-28 attestation output:** the encryption algorithm in effect, surfaced as a
  Terraform output — machine-readable proof of encryption.

## Implementation status

All five controls are implemented in `solution/`:

1. CM-6 part 2 — `default_tags` block enforces the four tags (`solution/main.tf`).
2. SC-28 / AC-3 / CM-6 part 1 / AU-3+AU-6 — encryption, public-access blocks,
   versioning, and ownership-controls → ACL → logging are all present on the
   data and log buckets (`solution/main.tf`).
3. SC-28 attestation surfaced as the `encryption_algorithm` output
   (`solution/outputs.tf`).

Every control is reflected in `evidence/plan.json` (`terraform show -json`).
