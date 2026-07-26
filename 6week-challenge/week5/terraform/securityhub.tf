# ---------------------------------------------------------------------------
# RA-5 / SI-4 — Security Hub grades the account against the NIST 800-53 Rev 5
# baseline and emits findings. The standard subscription depends on the account
# being enabled first.
# ---------------------------------------------------------------------------
resource "aws_securityhub_account" "this" {}

resource "aws_securityhub_standards_subscription" "nist" {
  depends_on    = [aws_securityhub_account.this]
  standards_arn = "arn:aws:securityhub:${var.region}::standards/nist-800-53/v/5.0.0"
}
