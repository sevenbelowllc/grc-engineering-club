# Keyless CI identity — GitHub OIDC → short-lived AWS credentials, no stored keys.
#
# Adapted from 6week-challenge/week-3/oidc/iam-oidc.tf. Two resources:
#
#   1. A GitHub OIDC identity provider in this AWS account.
#   2. An IAM role only the workflows in THIS repo can assume.
#
# The role's ARN is consumed directly by vault.tf in this same module, and is
# emitted as an output to set as the repo Actions variable AWS_GATE_ROLE_ARN.

# AWS validates the token signature against its own trust store, so the
# thumbprint is largely a formality now — but the provider still requires one,
# and pinning the documented root keeps apply deterministic.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Trust policy: assume-role is allowed only for a token that
#   - was issued by the GitHub OIDC provider above,
#   - carries audience sts.amazonaws.com, and
#   - carries a `sub` claim for this exact repo (any branch/PR/tag).
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

    # `:*` covers every ref (pull_request, branches, tags) in THIS repo — it is
    # not a cross-repo wildcard.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "grc_gate" {
  name                 = "grc-gate-oidc"
  description          = "Role the grc-gate CI workflow assumes via GitHub OIDC: read-only plan generation plus write-only evidence vaulting."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Generating a Terraform plan needs to describe existing state; it never needs to
# create, modify, or delete. Least privilege: the AWS-managed read-only set.
#
# Note the vault write is NOT granted here. It is granted by the vault's own
# bucket policy (vault.tf), scoped to that one bucket and to s3:PutObject alone.
# Keeping the write on the resource side means this role's identity policy stays
# strictly read-only, and the single mutating permission it holds is legible in
# one place rather than buried in a managed policy.
resource "aws_iam_role_policy_attachment" "read_only" {
  role       = aws_iam_role.grc_gate.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
