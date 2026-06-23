terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region

  # TODO (CM-6): add a default_tags block so every taggable resource carries
  # Project, Environment, ManagedBy, and ComplianceScope automatically.
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  primary_name = "${var.project_name}-${var.environment}-data-${random_id.suffix.hex}"
  log_name     = "${var.project_name}-${var.environment}-logs-${random_id.suffix.hex}"
}

# The two base buckets are here so the skeleton validates. The controls are yours.
resource "aws_s3_bucket" "primary" {
  bucket = local.primary_name
}

resource "aws_s3_bucket" "log" {
  bucket = local.log_name
}

# ---------------------------------------------------------------------------
# YOUR BUILD: add the controls. Each is one or more resources you write.
#
#   SC-28  encrypt the primary bucket at rest, and the log bucket too.
#   CM-6   turn on versioning for the primary bucket.
#   AC-3   block public access on both buckets. All four flags must be true.
#   AU-3   let the log bucket receive access logs (ownership controls, then a
#          log-delivery-write ACL), and point the primary bucket's logging at it.
#
# Look up the AWS provider resource names in the Terraform registry. The full
# brief on Patreon explains what each control is and how to verify it.
# ---------------------------------------------------------------------------
