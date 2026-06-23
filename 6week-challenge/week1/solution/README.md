# week-1 — reference solution

The complete, working implementation of all five week-1 controls. This is the
**answer key** — do not ship it as the starter. Members build the controls
themselves in `../main.tf`; this directory is for instructors and for generating
the reference `evidence/plan.json`.

Unlike the starter, this module stores state in the **remote S3 backend** created
by `../../bootstrap`. It therefore requires Terraform **≥ 1.10** (native
`use_lockfile` locking).

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
# 0. State bucket must exist first — see ../../bootstrap/README.md
cd ../../bootstrap && terraform output state_bucket_name   # note the name

# 1. Point this module at the backend
cd ../week-1/solution
cp backend.hcl.example backend.hcl                         # paste bucket name + region
cp terraform.tfvars.example terraform.tfvars               # edit project/env/region
terraform init -backend-config=backend.hcl

# 2. Generate evidence (week 2 reads this)
terraform plan -out tfplan
mkdir -p ../evidence
terraform show -json tfplan > ../evidence/plan.json

# 3. (optional) apply + verify live
terraform apply tfplan
terraform output encryption_algorithm                      # -> "AES256"  (SC-28 proof)
```

`../verify.sh` runs the three live checks (encryption, versioning, public-access
block) against the applied primary bucket.

## Tear down

Versioned buckets will not destroy while they hold object versions. Empty them
first, then `terraform destroy`.
