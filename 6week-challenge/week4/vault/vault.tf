# Dormant immutable evidence vault: an S3 bucket that even its owner cannot
# overwrite or delete before the retention window expires. Apply only for the
# preservation stretch; tear down the same day (pennies). Nothing here runs in
# CI until you set the EVIDENCE_VAULT_BUCKET repo variable to this bucket name.
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}
variable "bucket_name" { type = string }
variable "pipeline_role_arn" {
  type        = string
  description = "ARN of the GitHub OIDC role allowed to write the vault (week3 gate role)."
}

provider "aws" { region = var.region }

resource "aws_s3_bucket" "vault" {
  bucket              = var.bucket_name
  object_lock_enabled = true   # must be set at creation; cannot be added later
  tags = {
    project     = "grc-challenge"
    environment = "dev"
    owner       = "grc-eng-club"
    data-class  = "evidence"
  }
}

resource "aws_s3_bucket_versioning" "vault" {
  bucket = aws_s3_bucket.vault.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_object_lock_configuration" "vault" {
  bucket     = aws_s3_bucket.vault.id
  depends_on = [aws_s3_bucket_versioning.vault]
  rule {
    default_retention {
      mode = "COMPLIANCE"   # even root cannot shorten or delete before expiry
      days = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "vault" {
  bucket                  = aws_s3_bucket.vault.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "vault_write" {
  statement {
    sid       = "PipelinePutOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.vault.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [var.pipeline_role_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "vault" {
  bucket = aws_s3_bucket.vault.id
  policy = data.aws_iam_policy_document.vault_write.json
}

output "bucket_name" { value = aws_s3_bucket.vault.id }
