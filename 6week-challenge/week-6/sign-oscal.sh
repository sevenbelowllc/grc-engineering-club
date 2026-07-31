#!/usr/bin/env bash
# sign-oscal.sh — make the control mapping itself tamper-evident.
#
# Weeks 4 and 5 sign the *evidence*. This signs the *claim*.
#
# That is not decoration. The component definition is the document that says
# which Terraform resource satisfies SC-28 and which bundle proves it. An
# attacker who cannot forge the evidence can still repoint the claim — swap the
# href, weaken the description, quietly drop a control — and the evidence stays
# perfectly valid while attesting to something nobody is claiming any more. A
# signed evidence bundle behind an unsigned index is a strong lock on a door
# somebody can move.
#
# So the same four legs apply to the OSCAL as to everything else:
#   integrity     sha256 sidecar
#   authenticity  cosign keyless signature over the bundle
#   timeliness    Rekor transparency-log inclusion, countersigned
#   preservation  the vault, via the CI pipeline
#
# Keyless signing opens a browser once for OIDC. In CI the same signature is
# produced non-interactively from the workflow's OIDC token — see
# .github/workflows/grc-gate.yml, which is the authoritative signer.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OSCAL="$HERE/oscal"
EV="$HERE/evidence"
BUNDLE="$EV/oscal-documents.tar.gz"

mkdir -p "$EV"

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

# Sign the documents, not the workspace. .trestle/, dist/ and the empty model
# directories are scaffolding — including them would mean the signature changes
# whenever trestle's own layout changes, which makes the signature about the
# wrong thing.
DOCS=(
  "profiles/grc-pipeline-controls/profile.json"
  "component-definitions/grc-pipeline/component-definition.json"
  "assessment-plans/grc-pipeline-assessment/assessment-plan.json"
  "assessment-results/grc-gate-run/assessment-results.json"
  "assessment-results/broken-plan-negative-control/assessment-results.json"
)

for d in "${DOCS[@]}"; do
  [ -f "$OSCAL/$d" ] || fail "missing document: oscal/$d"
done

# Validate before signing. Signing an invalid document produces a cryptographic
# guarantee that a broken artifact is authentically broken.
echo "==> validating"
( cd "$OSCAL" && trestle validate -a )

echo
echo "==> bundling"
tar -C "$OSCAL" -czf "$BUNDLE" "${DOCS[@]}"

write_sha256_sidecar "$BUNDLE"

echo
echo "==> signing (a browser will open for OIDC)"
cosign sign-blob --yes --bundle "$BUNDLE.sig.bundle" "$BUNDLE"

echo
echo "Signed: $BUNDLE"
echo
echo "Verify with week 4's verifier, pinning the identity you just used:"
echo "  EXPECT_ISSUER='https://accounts.google.com' \\"
echo "  EXPECT_IDENTITY='^dkramer@sevenbelow\\.com$' \\"
echo "  ../week-4/verify-evidence.sh $BUNDLE"
