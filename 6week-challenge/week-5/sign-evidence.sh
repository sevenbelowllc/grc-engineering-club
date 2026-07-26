#!/usr/bin/env bash
# sign-evidence.sh — bundle + hash + keyless-sign the evidence into the week-4 chain.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EV="$HERE/evidence"
BUNDLE="$EV/week5-evidence.tar.gz"

tar -C "$EV" -czf "$BUNDLE" \
  security-hub-findings.json cloudtrail-status.json replica-listing.txt
shasum -a 256 "$BUNDLE" > "$BUNDLE.sha256"

# Keyless: opens a browser once for OIDC identity. Note the issuer + identity it
# prints — you pin them when verifying.
cosign sign-blob --yes --bundle "$BUNDLE.sig.bundle" "$BUNDLE"

echo
echo "Signed: $BUNDLE"
echo "Verify with the week-4 script, pinning the identity you just used, e.g.:"
echo "  EXPECT_ISSUER='https://github.com/login/oauth' \\"
echo "  EXPECT_IDENTITY='^dkramer@sevenbelow\\.com$' \\"
echo "  ../week-4/verify-evidence.sh $BUNDLE"
