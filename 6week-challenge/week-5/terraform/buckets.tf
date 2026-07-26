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
