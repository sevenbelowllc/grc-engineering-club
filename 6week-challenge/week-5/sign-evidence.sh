#!/usr/bin/env bash
# sign-evidence.sh — bundle + hash + keyless-sign the evidence into the week-4 chain.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EV="$HERE/evidence"
BUNDLE="$EV/week5-evidence.tar.gz"

# GNU coreutils ships `sha256sum`; macOS ships `shasum`. Prefer sha256sum so this
# runs unmodified on a Linux CI runner or in a container, and fall back so it
# still works on a developer's Mac. Both emit the identical "<hash>  <name>"
# format, so a sidecar written by either is readable by `sha256sum -c` and by
# `shasum -c` alike.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    echo "need sha256sum or shasum on PATH" >&2
    exit 1
  fi
}

tar -C "$EV" -czf "$BUNDLE" \
  security-hub-findings.json cloudtrail-status.json replica-listing.txt
# Write the sidecar with a RELATIVE filename, not an absolute one. An absolute
# path bakes this machine's home directory into published evidence and makes
# `sha256sum -c` fail for anyone who clones the repo. Running from $EV keeps the
# recorded name bare, so `cd evidence && sha256sum -c week5-evidence.tar.gz.sha256`
# works anywhere. Field 1 is still the hash, so week-4's verify-evidence.sh
# (which does `awk '{print $1}'`) reads it unchanged.
( cd "$EV" && sha256_file "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )

# Keyless: opens a browser once for OIDC identity. Note the issuer + identity it
# prints — you pin them when verifying.
cosign sign-blob --yes --bundle "$BUNDLE.sig.bundle" "$BUNDLE"

echo
echo "Signed: $BUNDLE"
echo "Verify with the week-4 script, pinning the identity you just used. EXPECT_ISSUER"
echo "must be the provider you actually authenticated with at the cosign prompt — a"
echo "wrong pin fails verification on a bundle that is perfectly good. The bundle"
echo "committed to this repo was signed through Google:"
echo "  EXPECT_ISSUER='https://accounts.google.com' \\"
echo "  EXPECT_IDENTITY='^dkramer@sevenbelow\\.com$' \\"
echo "  ../week-4/verify-evidence.sh $BUNDLE"
