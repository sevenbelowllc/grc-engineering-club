# Immutable evidence vault — the preservation leg of the chain of custody.
#
# Adapted from 6week-challenge/week-4/vault/vault.tf. The hash sidecar proves
# evidence was not *edited*; nothing in a signature stops it being *deleted*.
# Object Lock in COMPLIANCE mode closes that gap: once an object lands, no
# principal — including the account root — can delete or overwrite it until
# retention expires. That is genuine WORM, and it is why this maps to real
# records-retention regulation rather than being a deny-delete IAM policy a
# privileged user could edit away.
#
# Difference from the week-4 original: the bucket policy references the OIDC role
# created in this same module, so there is no manual pipeline_role_arn hand-off.

resource "aws_s3_bucket" "vault" {
  bucket = "${var.project_name}-evidence-vault-${random_id.suffix.hex}"

  # Simplest to set at creation. (Since 2023-11 AWS also supports enabling Object
  # Lock on an existing versioned bucket via PutObjectLockConfiguration.)
  object_lock_enabled = true

  tags = {
    data-class = "evidence"
  }
}

# Object Lock requires versioning. This must settle before the lock config
# applies, hence the explicit dependency below.
resource "aws_s3_bucket_versioning" "vault" {
  bucket = aws_s3_bucket.vault.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "vault" {
  bucket     = aws_s3_bucket.vault.id
  depends_on = [aws_s3_bucket_versioning.vault]

  rule {
    default_retention {
      # COMPLIANCE, not GOVERNANCE. Governance mode can be overridden by a caller
      # holding s3:BypassGovernanceRetention, which would not satisfy a strict
      # WORM requirement. COMPLIANCE cannot be bypassed by anyone.
      mode = "COMPLIANCE"
      days = var.vault_retention_days
    }
  }
}

# Evidence is never public. All four vectors blocked.
resource "aws_s3_bucket_public_access_block" "vault" {
  bucket                  = aws_s3_bucket.vault.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encryption at rest (SC-28), consistent with every other bucket in this build.
resource "aws_s3_bucket_server_side_encryption_configuration" "vault" {
  bucket = aws_s3_bucket.vault.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The CI role may PUT evidence and nothing else — no GetObject, no DeleteObject,
# no ListBucket. A pipeline that can read back or enumerate the vault is a
# pipeline that can be used to find and target evidence. Write-only is the whole
# point: deposit, never retrieve.
#
# Same-account note: S3 evaluates identity and resource policies as a union, so
# this grant is sufficient on its own even though the role's identity policy is
# strictly ReadOnlyAccess.
data "aws_iam_policy_document" "vault_write" {
  statement {
    sid       = "PipelinePutOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.vault.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.grc_gate.arn]
    }
  }

  # Deliberately NOT here: the classic "Deny PutObject unless
  # s3:x-amz-server-side-encryption == AES256" statement.
  #
  # It would break this pipeline and buy nothing. The CI upload runs
  # `aws s3api put-object` with no --server-side-encryption flag, so the request
  # carries no x-amz-server-side-encryption header at all — and StringNotEquals
  # against an absent key evaluates TRUE, so the Deny fires and every upload is
  # rejected. The object would still have been encrypted; the request just never
  # said so.
  #
  # It is also obsolete. S3 has encrypted all new objects with AES256 by default
  # since January 2023, and aws_s3_bucket_server_side_encryption_configuration
  # above makes that explicit. The control is enforced at the bucket, which
  # covers every caller, rather than at the request, which only covers callers
  # who remember to ask.
}

resource "aws_s3_bucket_policy" "vault" {
  bucket = aws_s3_bucket.vault.id
  policy = data.aws_iam_policy_document.vault_write.json

  # A bucket policy applied before the public access block can be rejected.
  depends_on = [aws_s3_bucket_public_access_block.vault]
}
