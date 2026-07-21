#!/usr/bin/env bash
# verify-evidence.sh <bundle.tar.gz>
# Proves an evidence bundle is intact and authentic. Exits non-zero on any
# failure; prints CHAIN INTACT only when every executed check passes.
set -euo pipefail

BUNDLE="${1:?usage: verify-evidence.sh <bundle.tar.gz>}"
SIDECAR="${BUNDLE}.sha256"
SIGBUNDLE="${BUNDLE}.sig.bundle"

# Verify-blob pins. Defaults target the CI signer (this repo's grc-gate.yml).
# Override both for a locally-signed bundle.
EXPECT_ISSUER="${EXPECT_ISSUER:-https://token.actions.githubusercontent.com}"
EXPECT_IDENTITY="${EXPECT_IDENTITY:-^https://github.com/sevenbelowllc/grc-engineering-club/\.github/workflows/grc-gate\.yml@refs/.*$}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. INTEGRITY -----------------------------------------------------------
# Recompute the bundle's SHA-256 and compare to the sidecar written at creation.
[ -f "$BUNDLE" ]  || fail "bundle not found: $BUNDLE"
[ -f "$SIDECAR" ] || fail "sidecar not found: $SIDECAR"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$BUNDLE" | awk '{print $1}')"
else
  ACTUAL="$(shasum -a 256 "$BUNDLE" | awk '{print $1}')"   # macOS
fi
EXPECTED="$(awk '{print $1}' "$SIDECAR")"
[ "$ACTUAL" = "$EXPECTED" ] || fail "integrity: sha256 mismatch (bundle was modified)"
echo "integrity:    OK  ($ACTUAL)"

# --- 2. AUTHENTICITY + TIMELINESS ------------------------------------------
# cosign verify-blob validates the signature, the certificate identity, and the
# transparency-log inclusion (which carries the signed timestamp).
command -v cosign >/dev/null 2>&1 || fail "cosign not installed"
[ -f "$SIGBUNDLE" ] || fail "signature bundle not found: $SIGBUNDLE"

COSIGN_ERR="$(cosign verify-blob \
  --bundle "$SIGBUNDLE" \
  --certificate-oidc-issuer "$EXPECT_ISSUER" \
  --certificate-identity-regexp "$EXPECT_IDENTITY" \
  "$BUNDLE" 2>&1)" \
  || { echo "$COSIGN_ERR" >&2; fail "authenticity: cosign verify-blob rejected the signature/identity"; }
echo "authenticity: OK  (issuer=$EXPECT_ISSUER)"

# --- 3. PRESERVATION (stretch, dormant unless a vault is configured) --------
if [ -n "${EVIDENCE_VAULT_BUCKET:-}" ] && [ -n "${EVIDENCE_VAULT_KEY:-}" ]; then
  RETAIN="$(aws s3api get-object-retention \
    --bucket "$EVIDENCE_VAULT_BUCKET" --key "$EVIDENCE_VAULT_KEY" \
    --query 'Retention.RetainUntilDate' --output text 2>/dev/null)" \
    || fail "preservation: could not read object retention (check credentials/bucket/key)"
  [ -n "$RETAIN" ] && [ "$RETAIN" != "None" ] \
    || fail "preservation: no Object Lock retention set on $EVIDENCE_VAULT_KEY"
  # Parse the AWS ISO-8601 timestamp portably (handles Z, offsets, and
  # fractional seconds — BSD/macOS `date -jf` cannot). python3 is present on
  # macOS and the CI ubuntu runner.
  RETAIN_EPOCH="$(python3 -c 'import sys,datetime; s=sys.argv[1].replace("Z","+00:00"); print(int(datetime.datetime.fromisoformat(s).timestamp()))' "$RETAIN" 2>/dev/null)" \
    || fail "preservation: could not parse retention date: $RETAIN"
  NOW_EPOCH="$(date -u +%s)"
  [ "$RETAIN_EPOCH" -gt "$NOW_EPOCH" ] || fail "preservation: retention $RETAIN is not in the future"
  echo "preservation: OK  (locked until $RETAIN)"
else
  echo "preservation: skipped (no vault configured)"
fi

echo "CHAIN INTACT"
