# Capstone deployment — keyless CI identity + immutable evidence vault

One `terraform apply` stands up the last two pieces of the pipeline: the identity
CI uses to prove who it is, and the vault that makes signed evidence undeletable.

## What it creates

| Resource | Why |
|---|---|
| `aws_iam_openid_connect_provider.github` | Lets GitHub Actions exchange a workflow token for AWS credentials — no stored keys |
| `aws_iam_role.grc_gate` | Assumable **only** by workflows in this repo; `ReadOnlyAccess` attached |
| `aws_s3_bucket.vault` | The evidence vault |
| `..._object_lock_configuration` | **COMPLIANCE** mode — objects undeletable by anyone, including root |
| `..._versioning` | Required by Object Lock |
| `..._public_access_block` | All four vectors blocked; evidence is never public |
| `..._server_side_encryption_configuration` | AES256 at rest (SC-28) |
| `..._bucket_policy` | Grants the CI role `s3:PutObject` **and nothing else** |

Ten resources total.

## Why this module exists, and what it composes

The designs come from earlier weeks and those files remain their weeks'
deliverables:

- `oidc.tf` ← [`week-3/oidc/iam-oidc.tf`](../../week-3/oidc/iam-oidc.tf)
- `vault.tf` ← [`week-4/vault/vault.tf`](../../week-4/vault/vault.tf)

They are adapted here rather than consumed as child modules because each declares
its own `provider` block — legacy practice inside a module, and it blocks a clean
destroy.

Composing them buys one concrete thing. The vault's bucket policy names the CI
role as its principal, and **an S3 bucket policy cannot reference a principal that
does not exist**. As two separate root modules, the vault simply could not apply
until the OIDC role had been applied first and its ARN copied across by hand. In
one module, `aws_iam_role.grc_gate.arn` is an ordinary reference and Terraform
orders it for you.

## Write-only by design

The bucket policy grants `s3:PutObject` alone — no `GetObject`, no `DeleteObject`,
no `ListBucket`. A pipeline that can read back or enumerate the vault is a
pipeline that can be used to *find* evidence. Deposit, never retrieve.

The role's own identity policy stays strictly `ReadOnlyAccess`; the single
mutating permission it holds lives in the bucket policy, scoped to one bucket, in
one legible place. Same-account S3 evaluates identity and resource policies as a
union, so the resource-side grant is sufficient on its own.

## Apply

```bash
cd 6week-challenge/week-6/terraform
terraform init
terraform plan -out=capstone.tfplan     # review before applying
terraform apply capstone.tfplan
```

Then set the two outputs as GitHub Actions **repository variables**
(Settings → Secrets and variables → Actions → Variables) — not secrets; neither
is confidential:

| Output | Repo variable |
|---|---|
| `gate_role_arn` | `AWS_GATE_ROLE_ARN` |
| `vault_bucket` | `EVIDENCE_VAULT_BUCKET` |

Until **both** are set, the vault upload step in
[`grc-gate.yml`](../../../.github/workflows/grc-gate.yml) stays skipped rather
than failing. Setting them is the switch that turns the preservation path on.

## Verifying preservation

Once CI has vaulted a bundle, week 4's verifier picks up its dormant third check:

```bash
cd ../../week-4
EVIDENCE_VAULT_BUCKET=<vault_bucket> \
EVIDENCE_VAULT_KEY=runs/<RUN_ID>/evidence.tar.gz \
  ./verify-evidence.sh evidence/evidence.tar.gz
```

`preservation: OK (locked until …)` replaces `preservation: skipped`. That line
is the whole point of this module.

## Teardown — read this before applying

`vault_retention_days` defaults to **30**, and COMPLIANCE mode means exactly what
it says: an uploaded object cannot be deleted by anyone, including the account
root, until its retention expires.

**Consequence: `terraform destroy` fails while any object is still locked.** Wait
out the retention window (30 days from the last upload at the default), empty the
bucket, then destroy. Cost in the meantime is pennies — the constraint is timing,
not money.

The IAM role and OIDC provider destroy cleanly at any time.

> **30 days is a demo value, not a compliant retention period.** Real SEC
> 17a-4 retention is measured in years. Object Lock is the *control*; satisfying a
> regulation also requires an appropriate period, a designated third party, and
> the surrounding audit process. See
> [`week-4/worm-vs-iam-preservation-deep-dive.md`](../../week-4/worm-vs-iam-preservation-deep-dive.md).
