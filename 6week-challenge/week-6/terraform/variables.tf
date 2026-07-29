variable "region" {
  type        = string
  description = "AWS region for the vault bucket. IAM is global; the region only affects S3."
  default     = "us-east-1"
}

variable "project_name" {
  type        = string
  description = "Tag value for Project, and the vault bucket name prefix."
  default     = "grc-challenge"
}

variable "environment" {
  type        = string
  description = "Tag value for Environment."
  default     = "dev"
}

# The trust condition binds the role to this repository and nothing looser. A
# wildcard here would let any repository on GitHub assume the role.
variable "github_repo" {
  type        = string
  description = "owner/repo whose Actions workflows may assume the gate role."
  default     = "sevenbelowllc/grc-engineering-club"
}

# COMPLIANCE-mode Object Lock cannot be shortened or bypassed by anyone,
# including the account root. Every uploaded object is undeletable for this many
# days, which also means the bucket cannot be destroyed until the last object's
# retention expires.
#
# 30 days is a demo value, NOT a compliant retention period — real SEC 17a-4
# retention is measured in years. Object Lock is the *control*; meeting a
# regulation additionally requires an appropriate period, a designated third
# party, and the surrounding audit process. See
# ../../week-4/worm-vs-iam-preservation-deep-dive.md.
#
# It was 1 day until the CI verifier arrived. verify-pipeline.sh checks that the
# vault's retention is still in the future, and at one day that check went red
# every day on pull requests that had changed nothing. 30 days is long enough
# that the check means something between runs and short enough to stay a demo.
variable "vault_retention_days" {
  type        = number
  description = "Object Lock COMPLIANCE retention in days. Objects are undeletable for this long."
  default     = 30

  validation {
    condition     = var.vault_retention_days >= 1
    error_message = "Retention must be at least 1 day."
  }
}
