# Week 5 "Turn On the Cameras" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a multi-region CloudTrail (home `us-west-2`, log-file validation on) writing to an AES256 S3 bucket that replicates cross-region to `us-east-2`, plus Security Hub with the NIST 800-53 Rev 5 standard; capture the findings as evidence, sign them into the week-4 cosign chain, and tear it all down the same day.

**Architecture:** One `terraform apply` in the sandbox account `232929535631`. Terraform is split into focused files (`versions`, `variables`, `buckets`, `cloudtrail`, `replication`, `securityhub`, `outputs`). Two AWS providers (default `us-west-2`, aliased `aws.replica` for `us-east-2`). A `terraform plan` gate reviews everything before any money is spent; a single go-live task applies, verifies, captures, signs, and destroys.

**Tech Stack:** Terraform ~> 1.6, AWS provider ~> 5.0, AWS CLI v2, cosign (keyless), bash, jq.

## Global Constraints

- **Account:** every apply targets AWS account `232929535631` via profile `default`. A Terraform `precondition` hard-fails if credentials resolve to any other account.
- **Regions:** primary/home `us-west-2`; replica `us-east-2`.
- **Encryption:** SSE-S3 `AES256` with `bucket_key_enabled = true` on both buckets (SC-28). No KMS.
- **CloudTrail:** `is_multi_region_trail = true`, `enable_log_file_validation = true`, management events only — **never** enable data events.
- **No AWS Organizations, no AWS Config, no CloudWatch Logs/SNS.** Config's absence is captured as evidence, not fixed.
- **Cost discipline:** apply and destroy the **same day**. `force_destroy = true` on both buckets so `destroy` never blocks on log objects.
- **Location:** all files under `6week-challenge/week5/`. The club's brief is **not** committed. Reuse `../week4/verify-evidence.sh`; do not duplicate it.
- **Tags (repo convention):** provider `default_tags` = `Project`, `Environment`, `ManagedBy=terraform`, `ComplianceScope=nist-800-53`.
- **Branch:** work on `week5-challenge` (already checked out). Commit after each task.

---

### Task 1: Scaffold, providers, variables

**Files:**
- Create: `6week-challenge/week5/terraform/versions.tf`
- Create: `6week-challenge/week5/terraform/variables.tf`
- Create: `6week-challenge/week5/terraform/terraform.tfvars.example`

**Interfaces:**
- Produces: providers `aws` (default, `us-west-2`) and `aws.replica` (`us-east-2`); `data.aws_caller_identity.current`; variables `region`, `replica_region`, `profile`, `project_name`, `environment`, `expected_account_id`.

- [ ] **Step 1: Install cosign (signing prerequisite)**

Run: `brew install cosign && cosign version`
Expected: prints a `GitVersion:` line (e.g. `v2.x.x`).

- [ ] **Step 2: Write `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

# Primary / home region. The multi-region trail lives here and records every region.
provider "aws" {
  region  = var.region
  profile = var.profile
  default_tags {
    tags = {
      Project         = var.project_name
      Environment     = var.environment
      ManagedBy       = "terraform"
      ComplianceScope = "nist-800-53"
    }
  }
}

# Replica region for cross-region replication of the audit-log bucket (AU-9).
provider "aws" {
  alias   = "replica"
  region  = var.replica_region
  profile = var.profile
  default_tags {
    tags = {
      Project         = var.project_name
      Environment     = var.environment
      ManagedBy       = "terraform"
      ComplianceScope = "nist-800-53"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  trail_name   = "${local.name_prefix}-trail"
  account_id   = data.aws_caller_identity.current.account_id
  # Deterministic trail ARN, built as a string so the bucket policy does not have
  # to reference the trail resource (that would be a dependency cycle).
  trail_arn    = "arn:aws:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${local.trail_name}"
  log_name     = "${local.name_prefix}-ct-${data.aws_caller_identity.current.account_id}-${random_id.suffix.hex}"
  replica_name = "${local.name_prefix}-ct-rep-${data.aws_caller_identity.current.account_id}-${random_id.suffix.hex}"
}

resource "random_id" "suffix" {
  byte_length = 4
}
```

- [ ] **Step 3: Write `variables.tf`**

```hcl
variable "region" {
  type        = string
  description = "Primary/home region for the trail and Security Hub."
  default     = "us-west-2"
}

variable "replica_region" {
  type        = string
  description = "Region that receives the cross-region replica of the log bucket."
  default     = "us-east-2"
}

variable "profile" {
  type        = string
  description = "AWS CLI profile to use. Must resolve to expected_account_id."
  default     = "default"
}

variable "project_name" {
  type        = string
  description = "Short identifier; part of bucket names and the Project tag."
  default     = "grc-week5"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name must be 3-21 lowercase alphanumerics or hyphens, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment; drives the Environment tag."
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "expected_account_id" {
  type        = string
  description = "Guard rail: apply refuses to run if credentials resolve elsewhere."
  default     = "232929535631"
}
```

- [ ] **Step 4: Write `terraform.tfvars.example`**

```hcl
region              = "us-west-2"
replica_region      = "us-east-2"
profile             = "default"
project_name        = "grc-week5"
environment         = "dev"
expected_account_id = "232929535631"
```

- [ ] **Step 5: Init and validate**

Run: `cd 6week-challenge/week5/terraform && terraform init && terraform validate`
Expected: `Terraform has been successfully initialized!` then `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add 6week-challenge/week5/terraform/versions.tf \
        6week-challenge/week5/terraform/variables.tf \
        6week-challenge/week5/terraform/terraform.tfvars.example \
        6week-challenge/week5/terraform/.terraform.lock.hcl
git commit -m "week5: terraform scaffold — providers (us-west-2 + us-east-2), variables"
```

---

### Task 2: Primary CloudTrail log bucket

**Files:**
- Create: `6week-challenge/week5/terraform/buckets.tf`

**Interfaces:**
- Consumes: `local.log_name`, `local.account_id`, `var.expected_account_id`, `data.aws_caller_identity.current`.
- Produces: `aws_s3_bucket.log` (the trail's log destination; versioned, AES256, private).

- [ ] **Step 1: Write `buckets.tf`**

```hcl
# ---------------------------------------------------------------------------
# Primary audit-log bucket (us-west-2). CloudTrail writes here.
# Account guard rail lives on this resource: the whole apply refuses to proceed
# against any account other than expected_account_id.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "log" {
  bucket        = local.log_name
  force_destroy = true # same-day teardown: allow destroy even with log objects present

  lifecycle {
    precondition {
      condition     = local.account_id == var.expected_account_id
      error_message = "Wrong AWS account: credentials resolve to ${local.account_id}, expected ${var.expected_account_id}. Refusing to create billable resources."
    }
  }
}

# SC-28 — encryption at rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "log" {
  bucket = aws_s3_bucket.log.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

# AC-3 — all four public-access doors closed.
resource "aws_s3_bucket_public_access_block" "log" {
  bucket                  = aws_s3_bucket.log.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# AU-9 groundwork — versioning is required on the source for cross-region
# replication and protects prior audit-log object states.
resource "aws_s3_bucket_versioning" "log" {
  bucket = aws_s3_bucket.log.id
  versioning_configuration { status = "Enabled" }
}
```

- [ ] **Step 2: Validate**

Run: `terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Plan (dry run — creates nothing)**

Run: `terraform plan -out=/dev/null`
Expected: plan shows `aws_s3_bucket.log`, `..._server_side_encryption_configuration.log`, `..._public_access_block.log`, `..._versioning.log`, `random_id.suffix` to add. No errors, no account precondition failure.

- [ ] **Step 4: Commit**

```bash
git add 6week-challenge/week5/terraform/buckets.tf
git commit -m "week5: primary AES256 log bucket with account guard, PAB, versioning"
```

---

### Task 3: CloudTrail bucket policy and the trail

**Files:**
- Create: `6week-challenge/week5/terraform/cloudtrail.tf`

**Interfaces:**
- Consumes: `aws_s3_bucket.log`, `local.trail_arn`, `local.trail_name`, `local.account_id`.
- Produces: `aws_cloudtrail.this` (the multi-region trail; `output` in Task 6 reads `.name` and `.arn`).

- [ ] **Step 1: Write `cloudtrail.tf`**

```hcl
# ---------------------------------------------------------------------------
# Bucket policy that lets the CloudTrail service write to the log bucket.
# Both statements are scoped by aws:SourceArn to THIS trail — the single most
# common failure point. local.trail_arn is a constructed string, so this policy
# does not reference aws_cloudtrail.this and there is no dependency cycle.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.log.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.log.arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "log" {
  bucket = aws_s3_bucket.log.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}

# ---------------------------------------------------------------------------
# The trail. Multi-region (records every region into the one bucket),
# with log-file validation on (AU-10 — hourly signed digest files).
# depends_on the policy so the bucket accepts writes at create time.
# ---------------------------------------------------------------------------
resource "aws_cloudtrail" "this" {
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.log.id
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  include_global_service_events = true
  depends_on                    = [aws_s3_bucket_policy.log]
}
```

- [ ] **Step 2: Validate**

Run: `terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Plan**

Run: `terraform plan -out=/dev/null`
Expected: adds `aws_s3_bucket_policy.log` and `aws_cloudtrail.this`. The trail's `arn` in the plan (known-after-apply) must correspond to `local.trail_arn` shape `arn:aws:cloudtrail:us-west-2:232929535631:trail/grc-week5-dev-trail`.

- [ ] **Step 4: Commit**

```bash
git add 6week-challenge/week5/terraform/cloudtrail.tf
git commit -m "week5: multi-region CloudTrail + aws:SourceArn-scoped bucket policy"
```

---

### Task 4: Cross-region replication to us-east-2

**Files:**
- Create: `6week-challenge/week5/terraform/replication.tf`

**Interfaces:**
- Consumes: `aws_s3_bucket.log`, `aws_s3_bucket_versioning.log`, `local.replica_name`, `local.name_prefix`, provider `aws.replica`.
- Produces: `aws_s3_bucket.replica` (us-east-2 copy; `output` in Task 6 reads `.id`).

- [ ] **Step 1: Write `replication.tf`**

```hcl
# ---------------------------------------------------------------------------
# AU-9 / CP-6 / CP-9 — replicate the audit-log bucket to us-east-2 so the
# evidence survives loss of the primary region. Single-account CRR; the
# cross-account "log archive" upgrade is noted in the README as future work.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "replica" {
  provider      = aws.replica
  bucket        = local.replica_name
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica.id
  versioning_configuration { status = "Enabled" } # required on the destination too
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "replica" {
  provider                = aws.replica
  bucket                  = aws_s3_bucket.replica.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role S3 assumes to perform replication.
data "aws_iam_policy_document" "replication_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  name               = "${local.name_prefix}-ct-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_assume.json
}

data "aws_iam_policy_document" "replication" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.log.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = ["${aws_s3_bucket.log.arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${aws_s3_bucket.replica.arn}/*"]
  }
}

resource "aws_iam_role_policy" "replication" {
  name   = "${local.name_prefix}-ct-replication"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication.json
}

resource "aws_s3_bucket_replication_configuration" "log" {
  # Replication requires versioning enabled on both ends first.
  depends_on = [aws_s3_bucket_versioning.log, aws_s3_bucket_versioning.replica]
  role       = aws_iam_role.replication.arn
  bucket     = aws_s3_bucket.log.id

  rule {
    id     = "cloudtrail-crr"
    status = "Enabled"
    filter {} # replicate every object
    delete_marker_replication { status = "Disabled" }
    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD"
    }
  }
}
```

- [ ] **Step 2: Validate**

Run: `terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Plan**

Run: `terraform plan -out=/dev/null`
Expected: adds `aws_s3_bucket.replica`, its versioning/SSE/PAB, `aws_iam_role.replication`, `aws_iam_role_policy.replication`, `aws_s3_bucket_replication_configuration.log`. No errors.

- [ ] **Step 4: Commit**

```bash
git add 6week-challenge/week5/terraform/replication.tf
git commit -m "week5: cross-region replication of log bucket to us-east-2 (AU-9)"
```

---

### Task 5: Security Hub + NIST 800-53 Rev 5

**Files:**
- Create: `6week-challenge/week5/terraform/securityhub.tf`

**Interfaces:**
- Consumes: `var.region`.
- Produces: `aws_securityhub_standards_subscription.nist` (`output` in Task 6 reads `.standards_arn`).

- [ ] **Step 1: Write `securityhub.tf`**

```hcl
# ---------------------------------------------------------------------------
# RA-5 / SI-4 — Security Hub grades the account against the NIST 800-53 Rev 5
# baseline and emits findings. The standard subscription depends on the account
# being enabled first.
# ---------------------------------------------------------------------------
resource "aws_securityhub_account" "this" {}

resource "aws_securityhub_standards_subscription" "nist" {
  depends_on    = [aws_securityhub_account.this]
  standards_arn = "arn:aws:securityhub:${var.region}::standards/nist-800-53/v/5.0.0"
}
```

- [ ] **Step 2: Validate**

Run: `terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Plan**

Run: `terraform plan -out=/dev/null`
Expected: adds `aws_securityhub_account.this` and `aws_securityhub_standards_subscription.nist`. No errors.

- [ ] **Step 4: Commit**

```bash
git add 6week-challenge/week5/terraform/securityhub.tf
git commit -m "week5: Security Hub with NIST 800-53 Rev 5 standard"
```

---

### Task 6: Outputs and the pre-spend plan gate

**Files:**
- Create: `6week-challenge/week5/terraform/outputs.tf`

**Interfaces:**
- Consumes: `aws_cloudtrail.this`, `aws_s3_bucket.log`, `aws_s3_bucket.replica`, `aws_securityhub_standards_subscription.nist`.
- Produces: outputs `trail_name`, `trail_arn`, `log_bucket_name`, `replica_bucket_name`, `nist_standard_arn`, `region` (consumed by the scripts in Task 7).

- [ ] **Step 1: Write `outputs.tf`**

```hcl
output "trail_name" {
  description = "CloudTrail trail name (used by capture-evidence.sh)."
  value       = aws_cloudtrail.this.name
}

output "trail_arn" {
  description = "CloudTrail trail ARN."
  value       = aws_cloudtrail.this.arn
}

output "log_bucket_name" {
  description = "Primary audit-log bucket (us-west-2)."
  value       = aws_s3_bucket.log.id
}

output "replica_bucket_name" {
  description = "Cross-region replica bucket (us-east-2)."
  value       = aws_s3_bucket.replica.id
}

output "nist_standard_arn" {
  description = "Subscribed NIST 800-53 Rev 5 standard ARN."
  value       = aws_securityhub_standards_subscription.nist.standards_arn
}

output "region" {
  description = "Primary region."
  value       = var.region
}
```

- [ ] **Step 2: Validate**

Run: `terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Full plan review gate (READ THIS before spending money)**

Run: `terraform plan`
Expected and must confirm:
- Plan header shows the correct account is NOT wrong (no precondition error).
- Resource count to add is the full set from Tasks 1–5 (buckets ×2, SSE ×2, PAB ×2, versioning ×2, bucket policy, trail, replication role/policy/config, security hub account + standard, random_id). Nothing to destroy, nothing to change.
- `enable_log_file_validation = true` and `is_multi_region_trail = true` on `aws_cloudtrail.this`.
- The bucket policy `aws:SourceArn` equals the trail ARN shape.

Do not proceed to Task 8 until this plan is clean.

- [ ] **Step 4: Commit**

```bash
git add 6week-challenge/week5/terraform/outputs.tf
git commit -m "week5: outputs + reviewed pre-spend plan"
```

---

### Task 7: Evidence and teardown scripts

**Files:**
- Create: `6week-challenge/week5/capture-evidence.sh`
- Create: `6week-challenge/week5/sign-evidence.sh`
- Create: `6week-challenge/week5/teardown.sh`
- Create: `6week-challenge/week5/evidence/.gitkeep`

**Interfaces:**
- Consumes: terraform outputs `trail_name`, `replica_bucket_name`; `../week4/verify-evidence.sh`.
- Produces: `evidence/cloudtrail-status.json`, `evidence/security-hub-findings.json`, `evidence/replica-listing.txt`, `evidence/week5-evidence.tar.gz{,.sha256,.sig.bundle}`.

- [ ] **Step 1: Write `capture-evidence.sh`**

```bash
#!/usr/bin/env bash
# capture-evidence.sh — pull the three pieces of week-5 evidence into evidence/.
# Safe to run repeatedly while the stack is up.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TFDIR="$HERE/terraform"
EV="$HERE/evidence"
REGION="$(terraform -chdir="$TFDIR" output -raw region)"
PROFILE="${AWS_PROFILE:-default}"
mkdir -p "$EV"

echo "1) CloudTrail status (expect IsLogging: true)"
TRAIL="$(terraform -chdir="$TFDIR" output -raw trail_name)"
aws cloudtrail get-trail-status --name "$TRAIL" --region "$REGION" --profile "$PROFILE" \
  > "$EV/cloudtrail-status.json"
jq '{IsLogging}' "$EV/cloudtrail-status.json"

echo "2) Security Hub findings (expect >= 1)"
aws securityhub get-findings --region "$REGION" --profile "$PROFILE" --max-results 50 \
  > "$EV/security-hub-findings.json"
echo "   findings: $(jq '.Findings | length' "$EV/security-hub-findings.json")"

echo "3) AU-9 replication evidence (us-east-2 replica object listing)"
REPLICA="$(terraform -chdir="$TFDIR" output -raw replica_bucket_name)"
aws s3 ls "s3://$REPLICA" --recursive --region us-east-2 --profile "$PROFILE" \
  > "$EV/replica-listing.txt" || true
echo "   replicated objects: $(wc -l < "$EV/replica-listing.txt")"
```

- [ ] **Step 2: Write `sign-evidence.sh`**

```bash
#!/usr/bin/env bash
# sign-evidence.sh — bundle + hash + keyless-sign the evidence into the week-4 chain.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EV="$HERE/evidence"
BUNDLE="$EV/week5-evidence.tar.gz"

tar -C "$EV" -czf "$BUNDLE" \
  security-hub-findings.json cloudtrail-status.json replica-listing.txt
shasum -a 256 "$BUNDLE" > "$BUNDLE.sha256"

# Keyless: opens a browser once for OIDC identity. Note the issuer + identity it
# prints — you pin them when verifying.
cosign sign-blob --yes --bundle "$BUNDLE.sig.bundle" "$BUNDLE"

echo
echo "Signed: $BUNDLE"
echo "Verify with the week-4 script, pinning the identity you just used, e.g.:"
echo "  EXPECT_ISSUER='https://github.com/login/oauth' \\"
echo "  EXPECT_IDENTITY='^dkramer@sevenbelow\\.com$' \\"
echo "  ../week4/verify-evidence.sh $BUNDLE"
```

- [ ] **Step 3: Write `teardown.sh`**

```bash
#!/usr/bin/env bash
# teardown.sh — capture evidence (safety), then destroy everything this week made.
# Run the SAME DAY you apply. This is the most important script of the week.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${AWS_PROFILE:-default}"

echo "1) Capturing evidence before destroy (in case you skipped it)..."
"$HERE/capture-evidence.sh" || echo "   (capture incomplete; continuing to destroy)"

echo "2) Destroying the stack..."
terraform -chdir="$HERE/terraform" destroy -auto-approve

echo
echo "3) Confirm nothing is left billing:"
echo "   aws cloudtrail describe-trails      --region us-west-2 --profile $PROFILE"
echo "   aws securityhub get-enabled-standards --region us-west-2 --profile $PROFILE"
```

- [ ] **Step 4: Make executable, syntax-check, seed evidence dir**

```bash
cd 6week-challenge/week5
chmod +x capture-evidence.sh sign-evidence.sh teardown.sh
touch evidence/.gitkeep
bash -n capture-evidence.sh && bash -n sign-evidence.sh && bash -n teardown.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 5: Commit**

```bash
git add 6week-challenge/week5/capture-evidence.sh \
        6week-challenge/week5/sign-evidence.sh \
        6week-challenge/week5/teardown.sh \
        6week-challenge/week5/evidence/.gitkeep
git commit -m "week5: capture, sign, and teardown scripts"
```

---

### Task 8: Go live — apply, verify, capture

**Files:** none created; this task operates the stack. **This is the billable step.**

**Interfaces:**
- Consumes: the full Terraform config, `capture-evidence.sh`.
- Produces: live evidence files in `evidence/`.

- [ ] **Step 1: Apply**

Run: `cd 6week-challenge/week5/terraform && terraform apply` (review, type `yes`)
Expected: `Apply complete!` with outputs printed. If the account precondition fires, STOP — wrong credentials.

- [ ] **Step 2: Verify the trail is logging**

Run: `aws cloudtrail get-trail-status --name "$(terraform output -raw trail_name)" --region us-west-2 --profile default | jq '.IsLogging'`
Expected: `true`.

- [ ] **Step 3: Wait for Security Hub to populate**

Wait **10–20 minutes** (Security Hub runs its checks asynchronously). Do not capture early.

- [ ] **Step 4: Capture evidence**

Run: `cd 6week-challenge/week5 && ./capture-evidence.sh`
Expected: `IsLogging: true`; `findings: <N>` with N ≥ 1; `replicated objects: <M>` (M may be 0 if replication lag hasn't caught up — re-run after a few minutes to populate AU-9 evidence).

- [ ] **Step 5: Confirm findings non-empty**

Run: `jq '.Findings | length' evidence/security-hub-findings.json`
Expected: a number ≥ 1. (Very likely includes "AWS Config should be enabled" — that is expected evidence of a gap, not an error.)

*No commit yet — evidence is committed in Task 10 after signing.*

---

### Task 9: Sign and verify the evidence chain

**Files:** none created; produces signature artifacts in `evidence/`.

**Interfaces:**
- Consumes: `sign-evidence.sh`, `../week4/verify-evidence.sh`.
- Produces: `evidence/week5-evidence.tar.gz{,.sha256,.sig.bundle}`.

- [ ] **Step 1: Sign**

Run: `cd 6week-challenge/week5 && ./sign-evidence.sh`
Expected: browser opens once; cosign prints the certificate identity + issuer used; `Signed: .../week5-evidence.tar.gz`. **Record the issuer and identity it prints.**

- [ ] **Step 2: Verify the chain**

Run (substitute the issuer/identity from Step 1):
```bash
EXPECT_ISSUER='<issuer from step 1>' \
EXPECT_IDENTITY='<regex matching the identity from step 1>' \
../week4/verify-evidence.sh evidence/week5-evidence.tar.gz
```
Expected: prints `integrity: OK`, `authenticity: OK`, `preservation: skipped`, then `CHAIN INTACT`.

- [ ] **Step 3: Tamper test (proves the chain works)**

```bash
cp evidence/week5-evidence.tar.gz /tmp/tampered.tar.gz
cp evidence/week5-evidence.tar.gz.sha256 /tmp/tampered.tar.gz.sha256
cp evidence/week5-evidence.tar.gz.sig.bundle /tmp/tampered.tar.gz.sig.bundle
echo "junk" >> /tmp/tampered.tar.gz
EXPECT_ISSUER='<issuer>' EXPECT_IDENTITY='<identity regex>' \
  ../week4/verify-evidence.sh /tmp/tampered.tar.gz
```
Expected: exits non-zero with `FAIL: integrity: sha256 mismatch (bundle was modified)`.

*No commit yet — evidence committed in Task 10.*

---

### Task 10: Tear down and confirm clean

**Files:** none created.

**Interfaces:**
- Consumes: `teardown.sh`.
- Produces: a destroyed stack; nothing billing.

- [ ] **Step 1: Destroy**

Run: `cd 6week-challenge/week5 && ./teardown.sh`
Expected: re-captures evidence, then `Destroy complete!` Prints the two confirmation commands.

- [ ] **Step 2: Confirm nothing is billing**

```bash
aws cloudtrail describe-trails --region us-west-2 --profile default \
  --query "trailList[?Name=='grc-week5-dev-trail']"
aws securityhub get-enabled-standards --region us-west-2 --profile default 2>&1 || true
```
Expected: empty trail list `[]`; Security Hub call reports not-subscribed (or no NIST standard). Optionally confirm both buckets are gone in the console.

- [ ] **Step 3: Commit the captured, signed evidence**

```bash
git add 6week-challenge/week5/evidence/security-hub-findings.json \
        6week-challenge/week5/evidence/cloudtrail-status.json \
        6week-challenge/week5/evidence/replica-listing.txt \
        6week-challenge/week5/evidence/week5-evidence.tar.gz \
        6week-challenge/week5/evidence/week5-evidence.tar.gz.sha256 \
        6week-challenge/week5/evidence/week5-evidence.tar.gz.sig.bundle
git commit -m "week5: captured + signed evidence (CloudTrail status, Security Hub findings, AU-9 replica)"
```

---

### Task 11: README and SUBMISSION

**Files:**
- Create: `6week-challenge/week5/README.md`
- Create: `6week-challenge/week5/SUBMISSION.md`

**Interfaces:**
- Consumes: the finished build + evidence. No code depends on this task.

- [ ] **Step 1: Write `README.md`**

Must contain, in the author's own words (the club's brief is **not** reproduced):
- **What this builds** — one paragraph: multi-region CloudTrail (home us-west-2) with log-file validation → AES256 bucket, replicated to us-east-2, plus Security Hub NIST 800-53 Rev 5.
- **Why log-file validation matters** — one paragraph: CloudTrail emits hourly signed digest files, so tampering with past log records is detectable (AU-10).
- **The Config gap note** — one paragraph: AWS Config is intentionally omitted (org SCP / cost); the Security Hub "AWS Config should be enabled" finding is captured as documented-gap evidence, not a mistake.
- **The us-east-2 replica** — one paragraph: cross-region replication protects audit logs against regional loss (AU-9/CP-6/CP-9); note the async lag and that the cross-account "log archive account" is the production upgrade (needs Organizations, out of scope here).
- **Cost + teardown** — one line: applied and destroyed the same day; pennies.
- **This exact control-mapping table:**

```markdown
| Control | Name | Implemented by |
|---|---|---|
| AU-2 | Event logging | CloudTrail records account activity |
| AU-12 | Audit record generation | Multi-region trail across the account |
| AU-10 | Non-repudiation | enable_log_file_validation (hourly signed digests) |
| AU-9 | Protection of audit information | Cross-region replication of the log bucket |
| CP-6 / CP-9 | Alternate storage site / backup | us-east-2 replica of audit logs |
| RA-5 | Vulnerability / config scanning | Security Hub NIST 800-53 checks |
| SI-4 | System monitoring | Security Hub findings |
| SC-28 | Protection at rest | AES256 on both buckets |
```

- **How to run** — `terraform apply`, wait 10–20 min, `./capture-evidence.sh`, `./sign-evidence.sh`, verify with `../week4/verify-evidence.sh`, `./teardown.sh`.

- [ ] **Step 2: Write `SUBMISSION.md`**

Mirror the structure of `6week-challenge/week4/SUBMISSION.md`. Must include:
- The controls satisfied (AU-2, AU-12, AU-10, AU-9, CP-6, CP-9, RA-5, SI-4, SC-28).
- Links to the evidence files under `evidence/`.
- The `CHAIN INTACT` verification result (and the tamper-test failure) demonstrating the findings joined the week-4 chain of custody.
- A one-line confirmation the stack was torn down the same day.

- [ ] **Step 3: Verify links resolve**

Run: `cd 6week-challenge/week5 && for f in $(grep -oE 'evidence/[A-Za-z0-9._-]+' SUBMISSION.md | sort -u); do test -e "$f" && echo "OK  $f" || echo "MISSING $f"; done`
Expected: every referenced evidence path prints `OK`.

- [ ] **Step 4: Commit**

```bash
git add 6week-challenge/week5/README.md 6week-challenge/week5/SUBMISSION.md
git commit -m "week5: README (control mapping, log-validation rationale) + SUBMISSION"
```

---

## Self-Review

**Spec coverage** (each spec section → task):
- Target env / account guard → Task 1 (vars) + Task 2 (precondition). ✓
- Non-goals (no Orgs/Config/data-events/CloudWatch) → enforced by omission; Config-gap documented in Task 11. ✓
- Primary bucket (SSE/PAB/versioning) → Task 2. ✓
- Bucket policy (`aws:SourceArn`) + circular-dep fix → Task 3. ✓
- Multi-region trail + log-file validation → Task 3. ✓
- Cross-region replication (bucket/role/config) → Task 4. ✓
- Security Hub + NIST standard → Task 5. ✓
- Outputs → Task 6. ✓
- Evidence capture + signing (cosign, verify-evidence.sh) → Tasks 7, 9. ✓
- Teardown + confirm clean → Tasks 7, 10. ✓
- Cost discipline (force_destroy, same-day) → Global Constraints + Task 2 + Task 10. ✓
- Control mapping + README/SUBMISSION → Task 11. ✓
- Acceptance criteria → Tasks 8 (IsLogging, findings≥1, non-empty), 9 (signature), 10 (destroy clean). ✓

**Placeholder scan:** No TBD/TODO. The only run-time-substituted values are the cosign issuer/identity (unknowable until the interactive sign) — Task 9 shows how to capture and pin them, which is the correct handling, not a placeholder.

**Type/name consistency:** output names (`trail_name`, `replica_bucket_name`, `region`) are produced in Task 6 and consumed verbatim by the Task 7 scripts. `local.trail_arn` (Task 1) is used by the Task 3 policy. Resource addresses referenced in Task 10's confirmation (`grc-week5-dev-trail`) match `local.trail_name` = `${project_name}-${environment}-trail` with the defaults. Consistent.
