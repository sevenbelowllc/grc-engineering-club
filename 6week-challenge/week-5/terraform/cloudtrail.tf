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
