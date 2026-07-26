#!/usr/bin/env bash
# capture-evidence.sh — pull the three pieces of week-5 evidence into evidence/.
# Safe to run repeatedly while the stack is up.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TFDIR="$HERE/terraform"
EV="$HERE/evidence"
REGION="$(terraform -chdir="$TFDIR" output -raw region)"
PROFILE="${AWS_PROFILE:-default}"
mkdir -p "$EV"

echo "1) CloudTrail status (expect IsLogging: true)"
TRAIL="$(terraform -chdir="$TFDIR" output -raw trail_name)"
aws cloudtrail get-trail-status --name "$TRAIL" --region "$REGION" --profile "$PROFILE" \
  > "$EV/cloudtrail-status.json"
jq '{IsLogging}' "$EV/cloudtrail-status.json"

echo "2) Security Hub findings (expect >= 1)"
aws securityhub get-findings --region "$REGION" --profile "$PROFILE" --max-results 50 \
  > "$EV/security-hub-findings.json"
echo "   findings: $(jq '.Findings | length' "$EV/security-hub-findings.json")"

echo "3) AU-9 replication evidence (us-east-2 replica object listing)"
REPLICA="$(terraform -chdir="$TFDIR" output -raw replica_bucket_name)"
aws s3 ls "s3://$REPLICA" --recursive --region us-east-2 --profile "$PROFILE" \
  > "$EV/replica-listing.txt" || true
echo "   replicated objects: $(wc -l < "$EV/replica-listing.txt")"
