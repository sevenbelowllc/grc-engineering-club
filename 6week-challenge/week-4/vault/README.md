# Stretch: the immutable evidence vault

True preservation means the signed bundle cannot be overwritten or deleted —
even by you — until its retention window expires. This is a **dormant** stretch:
nothing runs in CI until you set the `EVIDENCE_VAULT_BUCKET` repo variable.

## Apply (pennies, tear down same day)

```bash
cd 6week-challenge/week4/vault
terraform init
terraform apply \
  -var "bucket_name=grc-evidence-vault-$(date +%s)" \
  -var "pipeline_role_arn=<your week3 gate role ARN>"
```

## Push one bundle and verify preservation

```bash
aws s3api put-object --bucket "$BUCKET" --key run-1/evidence.tar.gz \
  --body 6week-challenge/week4/evidence/evidence.tar.gz
EVIDENCE_VAULT_BUCKET="$BUCKET" EVIDENCE_VAULT_KEY=run-1/evidence.tar.gz \
  ./6week-challenge/week4/verify-evidence.sh 6week-challenge/week4/evidence/evidence.tar.gz
```

## The overwrite test (the point)

```bash
# Object Lock in COMPLIANCE mode refuses this until retention expires:
aws s3api put-object --bucket "$BUCKET" --key run-1/evidence.tar.gz --body /tmp/tampered.tar.gz
# -> AccessDenied / operation blocked by object lock retention
```

A tampered bundle has nowhere to live except a laptop. The vault stays clean.

### Why COMPLIANCE mode, and why this is a recognized control

Object Lock in **COMPLIANCE** mode is genuine WORM (write-once-read-many): until
the retention date passes, no principal — including the account root — can delete
or overwrite the object or shorten its retention. This is not merely a
"deny-delete" IAM policy (which a privileged user could edit away); it is a
data-level retention property S3 enforces against everyone.

That distinction is why it maps to real records-retention regulation. AWS
commissioned an independent assessment from **Cohasset Associates** (a records-
management compliance firm) concluding that S3 Object Lock meets the
non-rewriteable, non-erasable (WORM) storage requirements of **SEC Rule
17a-4(f)**, **FINRA Rule 4511(c)**, and **CFTC Rule 1.31(c)** when retention is
applied. COMPLIANCE mode — the mode this vault uses (`vault.tf`) — is the tier
that cannot be bypassed; the weaker Governance mode can be overridden by a caller
holding `s3:BypassGovernanceRetention`, so it would not satisfy a strict WORM
requirement.

- AWS SEC 17a-4(f) compliance overview: <https://aws.amazon.com/compliance/secrule17a-4f/>
- Cohasset Associates assessment (2025): <https://d1.awsstatic.com/onedam/marketing-channels/website/aws/en_US/whitepapers/compliance/Amazon-S3-Compliance-Assessment-2025.pdf>

Note: `days = 1` in `vault.tf` is a cost-demo value, not a compliant retention
period — real 17a-4 retention is measured in years. Object Lock is the *control*;
meeting a regulation also requires an appropriate retention period, a designated
third party, and the surrounding audit process.

## Teardown

```bash
# Object Lock blocks deletes until retention (1 day) expires. Either wait a day,
# or if you must remove sooner, delete the bucket after the window; empty first.
terraform destroy \
  -var "bucket_name=$BUCKET" -var "pipeline_role_arn=<arn>"
```

## Enabling the CI upload step

The `grc-gate` workflow includes a dormant "Upload signed bundle to the
immutable vault" step gated on `if: always() && vars.EVIDENCE_VAULT_BUCKET != ''`.
Setting the `EVIDENCE_VAULT_BUCKET` repo variable alone is not sufficient to
make it succeed: the step shells out to `aws s3api put-object`, which needs
AWS credentials in the job. Enabling it for real requires wiring
`aws-actions/configure-aws-credentials` (OIDC) into the `grc-gate` job with a
role that has `s3:PutObject` on this vault — out of scope while dormant.
