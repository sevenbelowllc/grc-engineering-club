# ---------------------------------------------------------------------------
# AWS Config — REQUIRED for Security Hub standard controls to evaluate.
#
# Runtime discovery: with no configuration recorder, every Security Hub standard
# stays INCOMPLETE (StatusReasonCode: NO_AVAILABLE_CONFIGURATION_RECORDER) and
# generates ZERO findings. The challenge brief's claim that Config can be
# skipped and still yield findings does not hold for a fresh account — Config is
# a hard dependency for RA-5 / SI-4 findings. Same-day teardown keeps cost in
# cents. force_destroy on the bucket so destroy never stalls on snapshots.
# ---------------------------------------------------------------------------

locals {
  config_name = "${local.name_prefix}-config-${local.account_id}-${random_id.suffix.hex}"
}

# S3 bucket AWS Config delivers configuration snapshots to.
resource "aws_s3_bucket" "config" {
  bucket        = local.config_name
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy for the AWS Config service principal. Scoped by aws:SourceAccount.
# No s3:x-amz-acl condition — the bucket uses default ownership (ACLs disabled),
# so requiring that header would DENY legitimate deliveries.
data "aws_iam_policy_document" "config_bucket" {
  statement {
    sid       = "AWSConfigBucketPermissionsCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config.arn]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
  statement {
    sid       = "AWSConfigBucketExistenceCheck"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.config.arn]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
  statement {
    sid       = "AWSConfigBucketDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config.arn}/AWSLogs/${local.account_id}/Config/*"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = data.aws_iam_policy_document.config_bucket.json
}

# IAM role AWS Config assumes to read resource configurations across services.
data "aws_iam_policy_document" "config_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "${local.name_prefix}-config"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}

# AWS-managed policy: read access across services for the recorder.
resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Inline policy so the role can deliver snapshots to the Config bucket.
data "aws_iam_policy_document" "config_s3" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config.arn}/AWSLogs/${local.account_id}/Config/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config.arn]
  }
}

resource "aws_iam_role_policy" "config_s3" {
  name   = "${local.name_prefix}-config-s3"
  role   = aws_iam_role.config.id
  policy = data.aws_iam_policy_document.config_s3.json
}

# The recorder, its delivery channel, and the switch to turn it on.
resource "aws_config_configuration_recorder" "this" {
  name     = "${local.name_prefix}-recorder"
  role_arn = aws_iam_role.config.arn
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "${local.name_prefix}-channel"
  s3_bucket_name = aws_s3_bucket.config.id
  depends_on = [
    aws_config_configuration_recorder.this,
    aws_s3_bucket_policy.config,
  ]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [
    aws_config_delivery_channel.this,
    aws_iam_role_policy_attachment.config_managed,
    aws_iam_role_policy.config_s3,
  ]
}
