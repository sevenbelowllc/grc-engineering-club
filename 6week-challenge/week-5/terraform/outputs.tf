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
