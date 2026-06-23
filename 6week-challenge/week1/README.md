# Week 1 starter: Your First Compliant Resource

This is scaffolding, not a solution. The provider and both buckets are wired up so the project validates out of the box. Your job is to add the five controls marked `# TODO` in `main.tf`.

## Use it

```bash
terraform init
terraform validate        # passes as-is (skeleton), passes again once you finish
terraform plan -out=tfplan

mkdir -p evidence
terraform show -json tfplan > evidence/plan.json
```

## What to add (all in main.tf)

- SC-28: `aws_s3_bucket_server_side_encryption_configuration` on both buckets
- CM-6: `aws_s3_bucket_versioning` on the primary
- AC-3: `aws_s3_bucket_public_access_block` on both buckets (all four flags `true`)
- AU-3: `aws_s3_bucket_ownership_controls` + `aws_s3_bucket_acl` (log-delivery-write) + `aws_s3_bucket_logging`
- CM-6 tags are already enforced by the provider `default_tags` block

Then uncomment the `encryption_algorithm` output in `outputs.tf`.

## Done when

Run `./verify.sh` after `terraform apply`, or just confirm `evidence/plan.json` contains the encryption rule, the four-flag public access block, the four tags, and the logging block.

## Files

- `main.tf`: provider, buckets, and the TODOs you complete
- `variables.tf`: input variables (complete)
- `outputs.tf`: outputs (one is commented until you add encryption)
- `verify.sh`: post-apply control checks
- `terraform.tfvars.example`: copy to `terraform.tfvars` and edit
