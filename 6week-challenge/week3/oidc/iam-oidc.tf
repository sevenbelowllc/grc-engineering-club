# =============================================================================
# STRETCH: keyless CI via GitHub OIDC.
#
# Apply this ONCE, out of band, with your own admin credentials (it is not part
# of the week-1 build and the gate never applies it). It creates:
#
#   1. A GitHub OIDC identity provider in your AWS account.
#   2. An IAM role that ONLY the grc-gate workflow, running in THIS repo, can
#      assume — bound to repo:sevenbelowllc/grc-engineering-club:* and nothing
#      looser. The role carries read-only permissions.
#
# After `terraform apply`, take the role_arn output and set it as the repo
# Actions variable AWS_GATE_ROLE_ARN (see oidc/README-oidc.md). That variable is
# the switch that turns the grc-gate-oidc job on.
# =============================================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# Your exact repository. The trust condition binds to this and only this — a
# wildcard here would let any repository on GitHub assume the role.
variable "github_repo" {
  type    = string
  default = "sevenbelowllc/grc-engineering-club"
}

# GitHub's OIDC thumbprint list is maintained by AWS when this value is set from
# the well-known provider; pinning the documented root thumbprint keeps apply
# deterministic. AWS now validates the token signature against its trust store,
# so the thumbprint is a formality, but the provider still requires one.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Trust policy: assume-role is allowed only for a token that
#   - was issued by the GitHub OIDC provider above,
#   - has audience sts.amazonaws.com, and
#   - carries a `sub` claim for our exact repo (any branch/PR/tag).
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Bind to the exact repo. `:*` covers every ref (pull_request, branches,
    # tags) in THIS repo — not a cross-repo wildcard.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "grc_gate" {
  name                 = "grc-gate-oidc"
  description          = "Read-only role the grc-gate CI workflow assumes via GitHub OIDC to generate a Terraform plan."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Read-only. Generating a plan needs to describe existing state; it never needs
# to create, modify, or delete. Least privilege: attach AWS-managed ReadOnly.
# Tighten to a scoped s3:Get*/List* + ec2/sts describe policy if you want to go
# further than the managed set.
resource "aws_iam_role_policy_attachment" "read_only" {
  role       = aws_iam_role.grc_gate.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

output "role_arn" {
  description = "Set this as the repo Actions variable AWS_GATE_ROLE_ARN to enable the grc-gate-oidc job."
  value       = aws_iam_role.grc_gate.arn
}
