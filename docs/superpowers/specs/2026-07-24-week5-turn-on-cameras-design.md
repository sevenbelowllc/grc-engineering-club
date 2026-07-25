# Week 5 Design — "Turn On the Cameras"

**Date:** 2026-07-24
**Status:** Approved design, pending implementation plan
**Author:** David Kramer (with Claude)

## Goal

Turn on the native AWS controls that watch the *account itself*, capture what
they see as evidence, sign that evidence into the week-4 chain of custody, and
tear it all down the same day. This is the one week that creates billable
resources, so cost discipline and same-day teardown are first-class
requirements, not afterthoughts.

## Target environment

| Property | Value |
|---|---|
| AWS account | `232929535631` (sandbox) |
| AWS profile | `default` (IAM user `dkramer@sevenbelow.com`) |
| Primary / home region | `us-west-2` |
| Secondary (replica) region | `us-east-2` |
| Starting state (verified) | No CloudTrail trails; Security Hub not subscribed → build fresh, no Terraform imports |

## Non-goals (explicitly out of scope)

- **AWS Organizations** — not introduced. This is a single-account build. No
  organization trail, no delegated-administrator Security Hub.
- **Cross-account replication** — the gold-standard "log archive account"
  pattern needs a second account + Organizations. Out of scope; noted in the
  README as the upgrade path.
- **AWS Config** — optional and often blocked by an org SCP. Left out
  deliberately. The Security Hub finding "AWS Config should be enabled" is
  itself valid evidence of a documented control gap.
- **CloudTrail data events** — never enabled (they bill per event). Management
  events only, which are free.
- **CloudWatch Logs integration, SNS alarms (AU-6)** — scope creep beyond the
  brief. Not built.

## Architecture

One `terraform apply` stands up everything. Two AWS providers: the default
`us-west-2` and an aliased `aws.use2` for `us-east-2`.

### 1. Primary CloudTrail log bucket (us-west-2)

- `aws_s3_bucket` — name scoped with account id + region for global uniqueness;
  `force_destroy = true` for clean same-day teardown.
- `aws_s3_bucket_server_side_encryption_configuration` — `AES256` (SSE-S3) with
  `bucket_key_enabled = true`. Matches the week-1 convention. Satisfies SC-28.
- `aws_s3_bucket_public_access_block` — all four flags `true`.
- `aws_s3_bucket_versioning` — `Enabled`. Required for cross-region replication
  and strengthens AU-9.

### 2. CloudTrail bucket policy (the known snag)

- `aws_s3_bucket_policy` with two statements for principal
  `cloudtrail.amazonaws.com`:
  - `s3:GetBucketAcl` on the bucket ARN.
  - `s3:PutObject` on `<bucket-arn>/AWSLogs/<account-id>/*`.
  - **Both** statements conditioned on
    `StringEquals: { "aws:SourceArn": "<trail-arn>" }`, scoped to this trail.
- **Circular-dependency resolution:** the bucket policy needs the trail ARN and
  the trail needs the bucket. Resolve by constructing the trail ARN as a
  deterministic string
  (`arn:aws:cloudtrail:us-west-2:232929535631:trail/<trail-name>`) so the policy
  does not reference the trail resource. The trail then declares
  `depends_on = [aws_s3_bucket_policy.this]`.

### 3. The trail

- `aws_cloudtrail` with:
  - `is_multi_region_trail = true` — one trail, home region `us-west-2`,
    automatically records API activity from **all** regions (including
    `us-east-2`) into the one primary bucket.
  - `enable_log_file_validation = true` — hourly signed digest files; this flag
    is the AU-10 control.
  - `include_global_service_events = true`.
  - `depends_on = [aws_s3_bucket_policy.this]`.

### 4. Cross-region replication to us-east-2 (AU-9 / CP-6 / CP-9)

Real-world audit logs are replicated off the primary region so they survive a
regional failure or tampering. Single-account cross-region replication is the
sandbox-appropriate version of that pattern.

- **Destination bucket** (`provider = aws.use2`): `aws_s3_bucket` in
  `us-east-2` with versioning `Enabled` (required on both ends), `AES256`
  encryption, public-access-block all-four, `force_destroy = true`.
- **Replication IAM role** (`aws_iam_role` + `aws_iam_role_policy`) assumable by
  `s3.amazonaws.com`, granting:
  - source: `s3:GetReplicationConfiguration`, `s3:ListBucket`,
    `s3:GetObjectVersionForReplication`, `s3:GetObjectVersionAcl`,
    `s3:GetObjectVersionTagging`.
  - destination: `s3:ReplicateObject`, `s3:ReplicateDelete`,
    `s3:ReplicateTags`.
- `aws_s3_bucket_replication_configuration` on the primary bucket → destination,
  using the role. Requires versioning on the primary (already enabled).

**Caveats baked into the README:** replication is asynchronous (seconds-to-
minutes lag) and only replicates objects created *after* the config exists
(fine — CloudTrail writes logs after apply). Same-account replication protects
against *region* loss, not a malicious admin; the cross-account version is the
next step.

### 5. Security Hub (us-west-2)

- `aws_securityhub_account` — enable the account.
- `aws_securityhub_standards_subscription` — subscribe
  `arn:aws:securityhub:us-west-2::standards/nist-800-53/v/5.0.0`;
  `depends_on` the account. Runs a few hundred checks → findings for RA-5, SI-4.

### 6. Outputs

Trail ARN, primary bucket name, replica bucket name, subscribed standard ARN.

## Evidence and signing flow

After apply, wait **10–20 minutes** for Security Hub to populate findings, then
capture evidence *before* destroying:

1. `aws cloudtrail get-trail-status` → proves `IsLogging: true`.
2. `aws securityhub get-findings --region us-west-2 --max-results 50`
   → `evidence/security-hub-findings.json` (must be non-empty).
3. *(optional AU-9 evidence)* `aws s3 ls s3://<us-east-2-bucket> --recursive`
   showing replicated CloudTrail objects.
4. **Sign** via the week-4 pipeline: `tar.gz` the `evidence/` directory → write
   a `.sha256` sidecar → `cosign sign-blob --yes --bundle <bundle>.sig.bundle
   <bundle>`. Local keyless signing opens a browser once for OIDC identity.
5. **Verify** with the week-4 `verify-evidence.sh`, overriding `EXPECT_ISSUER`
   and `EXPECT_IDENTITY` to the *local* signer identity (the script's defaults
   target the CI signer). Expect `CHAIN INTACT`.

**Prerequisite:** `cosign` is not installed locally. Plan includes
`brew install cosign`. `terraform` (v1.15.8), `aws` (v2.36.8), and `jq` are
already present.

## Teardown (not optional)

`teardown.sh` (adapted from the branch starter) captures findings first, then
runs `terraform destroy -auto-approve`. `force_destroy = true` on both buckets
lets `destroy` empty and remove them even with log objects present. After
destroy, confirm:

- `aws cloudtrail describe-trails` → trail gone.
- `aws securityhub get-enabled-standards` / `describe-hub` → disabled.
- Both buckets removed; nothing left billing.

## Cost

Applied and destroyed the same day, the whole week stays in pennies:

- CloudTrail management events: **free**. No data events.
- Security Hub: ~$0.001/check × a few hundred checks → under ~$1/month, pennies
  for one hour.
- Cross-region replication: tiny per-object requests + cross-region transfer +
  ~2× storage on a few MB of one hour's logs → negligible.

## Control mapping

| Control | Name | Implemented by |
|---|---|---|
| AU-2 | Event logging | CloudTrail records account activity |
| AU-12 | Audit record generation | Multi-region trail across the account |
| AU-10 | Non-repudiation | `enable_log_file_validation` (hourly signed digests) |
| AU-9 | Protection of audit information | Cross-region replication of the log bucket |
| CP-6 / CP-9 | Alternate storage site / backup | us-east-2 replica of audit logs |
| RA-5 | Vulnerability / config scanning | Security Hub NIST 800-53 checks |
| SI-4 | System monitoring | Security Hub findings |
| SC-28 | Protection at rest | AES256 on both buckets |

## Deliverables and file layout

Under `6week-challenge/week5/` (matching weeks 1–4; the club's brief is **not**
committed here):

```
6week-challenge/week5/
  terraform/
    main.tf            # buckets, policy, trail, replication, security hub
    variables.tf
    outputs.tf
    terraform.tfvars.example
  evidence/
    security-hub-findings.json   # captured at run time
    (signature bundle + .sha256 sidecar)
  teardown.sh          # capture-then-destroy
  README.md            # control mapping, why validation matters, Config-gap note,
                       # cross-account upgrade path, replication caveats
  SUBMISSION.md        # in the style of prior weeks
```

Week-4's `verify-evidence.sh` is **reused**, not duplicated.

## Acceptance criteria ("Done when")

- [ ] `aws cloudtrail get-trail-status` shows `IsLogging: true` while up.
- [ ] `aws securityhub get-findings` returns ≥ 1 finding.
- [ ] `evidence/security-hub-findings.json` captured and non-empty.
- [ ] Findings file carries a valid signature from the week-4 pipeline
      (`verify-evidence.sh` → `CHAIN INTACT`).
- [ ] *(enhancement)* Replicated CloudTrail objects present in the us-east-2
      bucket.
- [ ] `terraform destroy` completes; no trail, Security Hub disabled, both
      buckets gone, nothing billing.

## Open risks

- **Replication lag vs. same-day teardown:** if capturing the AU-9 replication
  evidence, allow a few minutes after CloudTrail first writes before listing the
  destination bucket. Not a blocker for the required Security Hub evidence.
- **Local cosign identity:** the pinned `EXPECT_IDENTITY` must match whatever
  OIDC identity is used at sign time. Record the exact issuer/identity used so
  verification is reproducible.
- **Bucket policy `aws:SourceArn`:** the single most common failure point. The
  deterministic trail-ARN string approach must exactly match the created trail's
  ARN, or the trail will refuse to write.
