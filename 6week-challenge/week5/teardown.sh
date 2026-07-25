#!/usr/bin/env bash
# teardown.sh — capture evidence (safety), then destroy everything this week made.
# Run the SAME DAY you apply. This is the most important script of the week.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${AWS_PROFILE:-default}"

echo "1) Capturing evidence before destroy (in case you skipped it)..."
"$HERE/capture-evidence.sh" || echo "   (capture incomplete; continuing to destroy)"

echo "2) Destroying the stack..."
terraform -chdir="$HERE/terraform" destroy -auto-approve

echo
echo "3) Confirm nothing is left billing:"
echo "   aws cloudtrail describe-trails      --region us-west-2 --profile $PROFILE"
echo "   aws securityhub get-enabled-standards --region us-west-2 --profile $PROFILE"
