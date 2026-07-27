#!/usr/bin/env bash
# sign-evidence.sh — bundle + hash + keyless-sign the evidence into the week-4 chain.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EV="$HERE/evidence"
BUNDLE="$EV/week5-evidence.tar.gz"

tar -C "$EV" -czf "$BUNDLE" \
  security-hub-findings.json cloudtrail-status.json replica-listing.txt
# Write the sidecar with a RELATIVE filename, not an absolute one. An absolute
# path bakes this machine's home directory into published evidence and makes
# `shasum -c` fail for anyone who clones the repo. Running from $EV keeps the
# recorded name bare, so `cd evidence && shasum -c week5-evidence.tar.gz.sha256`
# works anywhere. Field 1 is still the hash, so week-4's verify-evidence.sh
# (which does `awk '{print $1}'`) reads it unchanged.
( cd "$EV" && shasum -a 256 "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )

# Keyless: opens a browser once for OIDC identity. Note the issuer + identity it
# prints — you pin them when verifying.
cosign sign-blob --yes --bundle "$BUNDLE.sig.bundle" "$BUNDLE"

echo
echo "Signed: $BUNDLE"
echo "Verify with the week-4 script, pinning the identity you just used, e.g.:"
echo "  EXPECT_ISSUER='https://github.com/login/oauth' \\"
echo "  EXPECT_IDENTITY='^dkramer@sevenbelow\\.com$' \\"
echo "  ../week-4/verify-evidence.sh $BUNDLE"
