#!/usr/bin/env bash
# sign-evidence.sh — bundle + hash + keyless-sign the evidence into the week-4 chain.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EV="$HERE/evidence"
BUNDLE="$EV/week5-evidence.tar.gz"

# --- shared helpers ---------------------------------------------------------
# Every function below is byte-identical wherever it appears. Where it appears:
#
#   fail                  week-4/verify-evidence.sh, week-5/sign-evidence.sh,
#                         week-6/sign-oscal.sh
#   sha256_file           week-4/verify-evidence.sh, week-5/sign-evidence.sh,
#                         week-6/sign-oscal.sh
#   write_sha256_sidecar  week-5/sign-evidence.sh, week-6/sign-oscal.sh
#   read_sha256_sidecar   week-4/verify-evidence.sh
#
# They are duplicated rather than sourced from a shared lib because each week
# directory has to stand alone — somebody copying week 4 out of this repo should
# get a working verifier, not a dangling `source ../../lib/hash.sh`. The price of
# that choice is drift, so the rule is blunt: change one, change all of them.

fail() { echo "FAIL: $*" >&2; exit 1; }

# GNU coreutils ships `sha256sum`; macOS ships `shasum`. Prefer sha256sum so
# this runs unmodified on a Linux CI runner or in a container, fall back so it
# still works on a developer's Mac, and fail loudly rather than skip the check
# if neither exists. Both emit the identical "<hash>  <name>" format, so either
# tool can verify the other's sidecar.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    fail "need sha256sum or shasum on PATH"
  fi
}

# Write <file>.sha256 beside <file>, recording a BARE filename.
#
# The `cd` is the entire point. Both tools record the path they were handed, so
# hashing an absolute path bakes the signer's home directory into published
# evidence and `sha256sum -c` then fails for everyone who clones the repo.
# Hashing from inside the directory keeps the recorded name bare, so
# `cd evidence && sha256sum -c <name>.sha256` works anywhere.
write_sha256_sidecar() {
  local target="$1" dir name
  [ -f "$target" ] || fail "cannot hash, no such file: $target"
  dir="$(cd "$(dirname "$target")" && pwd)" || fail "cannot resolve directory of: $target"
  name="$(basename "$target")"
  ( cd "$dir" && sha256_file "$name" > "$name.sha256" ) \
    || fail "could not write sidecar for: $target"
}

tar -C "$EV" -czf "$BUNDLE" \
  security-hub-findings.json cloudtrail-status.json replica-listing.txt
write_sha256_sidecar "$BUNDLE"

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
