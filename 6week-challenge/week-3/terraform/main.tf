terraform {
  # Local backend (state stays in this directory, gitignored). >= 1.6 is enough;
  # no remote S3 backend / native state locking is required for this submission.
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region

  # CM-6 (part two): four required tags on every taggable resource. The provider
  # default_tags block makes them impossible to forget on a new resource.
  default_tags {
    tags = {
      Project         = var.project_name
      Environment     = var.environment
      ManagedBy       = "terraform"
      ComplianceScope = "nist-800-53"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  primary_name = "${var.project_name}-${var.environment}-data-${random_id.suffix.hex}"
  log_name     = "${var.project_name}-${var.environment}-logs-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "primary" {
  bucket = local.primary_name
}

resource "aws_s3_bucket" "log" {
  bucket = local.log_name
}

# ---------------------------------------------------------------------------
# SC-28 — protection of information at rest. Encrypt both buckets by default.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "primary" {
  bucket = aws_s3_bucket.primary.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "log" {
  bucket = aws_s3_bucket.log.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------------------------
# CM-6 (part one) — configuration settings. Versioning on the primary so prior
# object states are recoverable and auditable.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "primary" {
  bucket = aws_s3_bucket.primary.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Beyond the week-1 minimum: versioning the log bucket too strengthens AU-9
# (protection of audit information). Not required by the brief; safe to keep.
resource "aws_s3_bucket_versioning" "log" {
  bucket = aws_s3_bucket.log.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------------------
# AC-3 — access enforcement. All four public-access flags true on both buckets.
# Three is not enough; they are four independent doors.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "primary" {
  bucket                  = aws_s3_bucket.primary.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "log" {
  bucket                  = aws_s3_bucket.log.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# AU-3 / AU-6 — audit record content and review. The primary logs access to the
# dedicated log bucket. Sequence matters (AccessDenied if you skip it):
#   1. ownership controls on the log bucket so it can accept an ACL
#   2. the log-delivery-write ACL
#   3. the logging resource on the primary pointing at the log bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_ownership_controls" "log" {
  bucket = aws_s3_bucket.log.id
  rule {
    # BucketOwnerPreferred (not BucketOwnerEnforced) — the log-delivery-write ACL
    # requires ACLs to be enabled on the destination bucket.
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "log" {
  # Ownership controls must exist before the ACL, or AWS returns AccessDenied.
  depends_on = [aws_s3_bucket_ownership_controls.log]

  bucket = aws_s3_bucket.log.id
  acl    = "log-delivery-write"
}

resource "aws_s3_bucket_logging" "primary" {
  bucket        = aws_s3_bucket.primary.id
  target_bucket = aws_s3_bucket.log.id
  target_prefix = "s3-access/"
}
