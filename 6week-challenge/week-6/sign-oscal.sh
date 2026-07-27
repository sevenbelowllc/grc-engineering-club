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
  [ -f "$OSCAL/$d" ] || { echo "missing document: oscal/$d" >&2; exit 1; }
done

# Validate before signing. Signing an invalid document produces a cryptographic
# guarantee that a broken artifact is authentically broken.
echo "==> validating"
( cd "$OSCAL" && trestle validate -a )

echo
echo "==> bundling"
tar -C "$OSCAL" -czf "$BUNDLE" "${DOCS[@]}"

# Relative filename in the sidecar, not absolute: an absolute path bakes this
# machine's home directory into published evidence and breaks `shasum -c` for
# anyone who clones the repo. (Same fix as week 5 — see its sign-evidence.sh.)
( cd "$EV" && shasum -a 256 "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )

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
