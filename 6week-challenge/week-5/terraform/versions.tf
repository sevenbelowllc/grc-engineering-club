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
