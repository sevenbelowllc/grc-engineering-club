# week-1 — Terraform module

The complete, working implementation of all five week-1 NIST 800-53 controls on
an S3 **data** bucket plus a dedicated S3 **access-log** bucket. Running
`terraform plan` here regenerates the reference `evidence/plan.json` that the
rest of the pipeline (week 2) reads.

State uses the **local backend** (`terraform.tfstate` in this directory, which is
gitignored) — no remote state bucket or bootstrap step is required. Terraform
**≥ 1.6**.

## Controls implemented

| Control | Resource(s) |
|---|---|
| SC-28 | `aws_s3_bucket_server_side_encryption_configuration` on both buckets (AES256) |
| CM-6 (versioning) | `aws_s3_bucket_versioning` on primary (and log, for AU-9) |
| CM-6 (tags) | provider `default_tags` block |
| AC-3 | `aws_s3_bucket_public_access_block` on both, all four flags true |
| AU-3 / AU-6 | `aws_s3_bucket_ownership_controls` → `aws_s3_bucket_acl` (log-delivery-write) → `aws_s3_bucket_logging` |

Plus the SC-28 attestation output (`encryption_algorithm`). See
`../compliance-mapping.md` for the full cross-framework mapping.

## Use

```bash
cp terraform.tfvars.example terraform.tfvars   # edit project/env/region

# Validate (no AWS credentials needed)
terraform init
terraform validate

# Generate evidence (week 2 reads this)
terraform plan -out tfplan
mkdir -p ../evidence
terraform show -json tfplan > ../evidence/plan.json

# (optional) apply + verify live — requires AWS credentials
terraform apply tfplan
terraform output encryption_algorithm          # -> "AES256"  (SC-28 proof)
```

`../verify.sh` runs the three live checks (encryption, versioning, public-access
block) against the applied primary bucket.

## Tear down

Versioned buckets will not destroy while they hold object versions. Empty them
first, then `terraform destroy`.
