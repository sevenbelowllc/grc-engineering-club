# Capstone deployment — provider and version pinning.
#
# Provenance: this root module composes two designs from earlier weeks into the
# single deployment the capstone actually applies:
#
#   - oidc.tf   adapted from 6week-challenge/week-3/oidc/iam-oidc.tf
#   - vault.tf  adapted from 6week-challenge/week-4/vault/vault.tf
#
# Those per-week files remain the deliverables for their weeks and still stand
# alone. They are NOT consumed here as child modules because each declares its
# own `provider` block, which is legacy practice inside a module and blocks a
# clean destroy. Composing them here instead buys one concrete improvement: the
# vault's bucket policy can reference the OIDC role created in this same module,
# eliminating the manual `pipeline_role_arn` hand-off between two separate
# applies — which was a real failure mode, since the vault cannot apply at all
# while that principal does not yet exist.
#
# Net effect: one `terraform apply` stands up the whole evidence-preservation
# chain instead of two applies with a manual variable copied between them.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project         = var.project_name
      Environment     = var.environment
      ManagedBy       = "terraform"
      ComplianceScope = "nist-800-53"
    }
  }
}

# Suffix keeps the vault bucket name globally unique across re-applies, matching
# the pattern used in weeks 1, 3, and 5.
resource "random_id" "suffix" {
  byte_length = 4
}
