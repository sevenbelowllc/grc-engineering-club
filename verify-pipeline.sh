#!/usr/bin/env bash
# verify-pipeline.sh — run every eligibility check for the six-week build and
# print one verdict.
#
# The challenge lists five things that have to pass end to end: terraform
# validate, conftest, trestle validate, cosign verify, and the vault upload.
# Those five live in five different directories with five different toolchains,
# which means "the pipeline passes" is normally a claim you take on trust
# because checking it is a twenty-minute chore.
#
# This makes it one command. A reviewer with the repo cloned and the tools
# installed types ./verify-pipeline.sh and gets PASS or FAIL — no walkthrough,
# no screenshots, no author present.
#
# Checks that cannot run in the current environment are reported as SKIP and
# named, never silently passed. A skipped check is a check nobody has done.
#
# Usage:
#   ./verify-pipeline.sh              # human output
#   ./verify-pipeline.sh --transcript # also write evidence/pipeline-verification.txt
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CH="$HERE/6week-challenge"
TRANSCRIPT="$CH/week-6/evidence/pipeline-verification.txt"

# --transcript re-runs the script with output teed to a file, colour stripped.
# Re-exec rather than threading a flag through every printf: the transcript is
# then provably the same output a reader gets on their own terminal, because it
# is literally that output.
if [ "${1:-}" = "--transcript" ]; then
  mkdir -p "$(dirname "$TRANSCRIPT")"
  {
    echo "# verify-pipeline.sh — every eligibility check for the six-week build."
    echo "# Captured $(date -u +%Y-%m-%dT%H:%M:%SZ). Reproduce: ./verify-pipeline.sh"
    echo
    "$0"
    echo
    echo "exit=$?"
  } 2>&1 | sed $'s/\033\\[[0-9;]*m//g' | tee "$TRANSCRIPT"
  exit "${PIPESTATUS[0]}"
fi

PASS=0; FAIL=0; SKIP=0
FAILED_CHECKS=()

green() { printf '\033[32m%s\033[0m' "$*"; }
red()   { printf '\033[31m%s\033[0m' "$*"; }
grey()  { printf '\033[90m%s\033[0m' "$*"; }

ok()   { printf '  [%s] %s\n' "$(green PASS)" "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [%s] %s\n' "$(red FAIL)" "$1"; FAIL=$((FAIL+1)); FAILED_CHECKS+=("$1"); }
skip() { printf '  [%s] %s\n    %s\n' "$(grey SKIP)" "$1" "$(grey "$2")"; SKIP=$((SKIP+1)); }

header() { printf '\n\033[1m%s\033[0m\n' "$1"; }

need() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
header "1. terraform validate — the infrastructure parses and type-checks"
# ---------------------------------------------------------------------------
if ! need terraform; then
  skip "terraform validate" "terraform is not installed"
else
  for d in week-1/solution week-3/terraform week-5/terraform week-6/terraform; do
    [ -d "$CH/$d" ] || continue
    if out="$( cd "$CH/$d" && terraform init -backend=false -input=false -no-color >/dev/null 2>&1 \
               && terraform validate -no-color 2>&1 )"; then
      ok "$d"
    else
      bad "$d — $(echo "$out" | head -3 | tr '\n' ' ')"
    fi
  done
fi

# ---------------------------------------------------------------------------
header "2. conftest — the policy gate denies what it is supposed to deny"
# ---------------------------------------------------------------------------
# Both directions. A gate that only ever passes has not been shown to be a gate:
# the negative case is what distinguishes a control from a decoration.
if ! need conftest; then
  skip "conftest" "conftest is not installed — see .github/workflows/grc-gate.yml for the pinned version"
else
  if ( cd "$CH/week-3" && conftest test --all-namespaces -p policies plan.json >/dev/null 2>&1 ); then
    ok "compliant plan passes the gate"
  else
    bad "compliant plan was denied by the gate"
  fi
  if ( cd "$CH/week-3" && conftest test --all-namespaces -p policies plan-broken.json >/dev/null 2>&1 ); then
    bad "broken plan PASSED the gate — the policy is not enforcing"
  else
    ok "broken plan is denied by the gate"
  fi
fi

# ---------------------------------------------------------------------------
header "3. trestle validate — the OSCAL documents are schema-valid"
# ---------------------------------------------------------------------------
if ! need trestle; then
  skip "trestle validate" "trestle is not installed (pip install compliance-trestle)"
else
  if out="$( cd "$CH/week-6/oscal" && trestle validate -a 2>&1 )"; then
    n="$(echo "$out" | grep -c '^VALID')"
    ok "all $n OSCAL documents VALID"
  else
    bad "trestle validate — $(echo "$out" | grep -v '^VALID' | head -2 | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------------------
header "4. cosign verify — the evidence is authentic and intact"
# ---------------------------------------------------------------------------
if ! need cosign; then
  skip "cosign verify" "cosign is not installed"
else
  # Each bundle carries its own signer pins. Week 4's was signed by the CI
  # workflow; week 5's from a workstation. Verifying with the wrong pin fails on
  # a bundle that is perfectly good, so the pins travel with the bundle.
  verify_bundle() {
    local label="$1" dir="$2" bundle="$3" issuer="$4" identity="$5"
    if out="$( cd "$CH/$dir" && EXPECT_ISSUER="$issuer" EXPECT_IDENTITY="$identity" \
               "$CH/week-4/verify-evidence.sh" "$bundle" 2>&1 )"; then
      ok "$label — $(echo "$out" | grep -c ': *OK') leg(s) verified, CHAIN INTACT"
    else
      bad "$label — $(echo "$out" | tail -2 | tr '\n' ' ')"
    fi
  }
  verify_bundle "week-4 gate evidence" week-4 evidence/evidence.tar.gz \
    "https://token.actions.githubusercontent.com" \
    '^https://github.com/sevenbelowllc/grc-engineering-club/\.github/workflows/grc-gate\.yml@refs/.*$'
  verify_bundle "week-5 runtime evidence" week-5 evidence/week5-evidence.tar.gz \
    "https://accounts.google.com" '^dkramer@sevenbelow\.com$'
fi

# ---------------------------------------------------------------------------
header "5. vault preservation — the evidence cannot be deleted"
# ---------------------------------------------------------------------------
VAULT_BUCKET="${EVIDENCE_VAULT_BUCKET:-grc-challenge-evidence-vault-f11fcaca}"
if ! need aws; then
  skip "vault preservation" "the AWS CLI is not installed"
elif ! aws sts get-caller-identity >/dev/null 2>&1; then
  skip "vault preservation" "no usable AWS credentials — this check reads Object Lock retention from the vault, which is private by design"
else
  for key in manual/2026-07-26/evidence.tar.gz manual/2026-07-26/week5-evidence.tar.gz; do
    retain="$(aws s3api get-object-retention --bucket "$VAULT_BUCKET" --key "$key" \
              --query 'Retention.RetainUntilDate' --output text 2>/dev/null)"
    mode="$(aws s3api get-object-retention --bucket "$VAULT_BUCKET" --key "$key" \
            --query 'Retention.Mode' --output text 2>/dev/null)"
    if [ -n "$retain" ] && [ "$retain" != "None" ] && [ "$mode" = "COMPLIANCE" ]; then
      ok "$(basename "$key") — COMPLIANCE lock until $retain"
    else
      bad "$(basename "$key") — no COMPLIANCE retention found in $VAULT_BUCKET"
    fi
  done
fi

# ---------------------------------------------------------------------------
header "6. traversal — profile to verified evidence, following only the documents"
# ---------------------------------------------------------------------------
if [ ! -x "$HERE/traverse.sh" ]; then
  skip "traversal" "traverse.sh not found or not executable"
elif ! need jq; then
  skip "traversal" "traverse.sh needs jq"
else
  if out="$("$HERE/traverse.sh" 2>&1)"; then
    # traverse.sh emits ANSI for its own terminal output; strip it before quoting.
    ok "$(echo "$out" | grep 'TRAVERSAL COMPLETE' | sed $'s/\033\\[[0-9;]*m//g; s/.*— //')"
  else
    bad "traversal — $(echo "$out" | grep -E 'BROKEN GRAPH|FETCH FAILED|FAIL:' | head -2 | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n%s\n' "------------------------------------------------------------------------"
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[1m%s\033[0m\n' "PIPELINE FAIL"
  for c in "${FAILED_CHECKS[@]}"; do echo "  - $c"; done
  exit 1
fi

if [ "$SKIP" -gt 0 ]; then
  printf '\n\033[1m%s\033[0m\n' "PIPELINE PASS (with $SKIP check(s) skipped — see above)"
  printf '%s\n' "A skipped check is a check nobody has done. Install the missing tools for a complete run."
  exit 0
fi

printf '\n\033[1m%s\033[0m\n' "PIPELINE PASS — every check ran and every check passed"
