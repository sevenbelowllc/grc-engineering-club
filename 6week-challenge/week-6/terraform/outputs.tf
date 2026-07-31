# The two values that turn the dormant CI vault path on. Both are set as GitHub
# Actions *repository variables* (Settings → Secrets and variables → Actions →
# Variables), not secrets — neither is confidential, and the workflow's `if:`
# conditions read them via `vars.`.

output "gate_role_arn" {
  description = "Set as repo Actions variable AWS_GATE_ROLE_ARN."
  value       = aws_iam_role.grc_gate.arn
}

output "vault_bucket" {
  description = "Set as repo Actions variable EVIDENCE_VAULT_BUCKET."
  value       = aws_s3_bucket.vault.id
}

output "vault_retention_days" {
  description = "Days each uploaded object stays undeletable. The bucket cannot be destroyed until the last object's retention expires."
  value       = var.vault_retention_days
}

# Convenience: the exact command to verify preservation on a vaulted object,
# using week 4's verifier with its dormant preservation check switched on.
output "verify_preservation_command" {
  description = "Run from 6week-challenge/week-4 after CI has vaulted a bundle."
  value = join(" ", [
    "EVIDENCE_VAULT_BUCKET=${aws_s3_bucket.vault.id}",
    "EVIDENCE_VAULT_KEY=runs/<RUN_ID>/evidence.tar.gz",
    "./verify-evidence.sh evidence/evidence.tar.gz",
  ])
}
