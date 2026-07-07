# Week 2 starter: Make the Rules Executable

You write the policies. This starter gives you the structure and the tests that define "done." Nothing here is the solution.

## What you get

- Three policy files, each with the required metadata header and an empty `deny` stub: SC-28 (encryption), AC-3 (public access block), CM-6 (required tags).
- Three test files. These are your spec. Do not edit them. Make them pass.

## Run the tests

```bash
opa test policies/ -v
```

Out of the box: **3 passing, 3 failing**. The passing ones confirm a compliant plan produces no denial. The failing ones are your work, each one says a non-compliant plan should be denied and right now your stub denies nothing.

Implement the three `deny` rules until it is **6 passing**.

## Then run it against your real week 1 plan

```bash
# in your week 1 terraform dir
terraform plan -out=tfplan
terraform show -json tfplan > plan.json

# back here
conftest test --policy policies --namespace compliance.sc28_aws plan.json
conftest test --policy policies --namespace compliance.ac3_aws  plan.json
conftest test --policy policies --namespace compliance.cm6_aws  plan.json
```

All three should pass against your compliant week 1 plan. Then break a copy of week 1 (delete the encryption block), regenerate the plan, and watch the matching policy fail with a message that names the resource and the fix.

## The one technique you need

At plan time, resource names are unknown (the random suffix is not generated yet), so you cannot match by value. Match by **reference**. `input.configuration.root_module.resources[].expressions.<arg>.references` holds strings like `"aws_s3_bucket.primary.id"`. Flag and tag values you read from `input.planned_values.root_module.resources[].values`. The test files show you the exact input shape.

## Files

- `policies/sc28_encryption_aws.rego`: your build
- `policies/ac3_no_public_aws.rego`: your build
- `policies/cm6_required_tags_aws.rego`: your build
- `policies/*_test.rego`: the spec, complete, do not edit
