#!/usr/bin/env bash
# traverse.sh — walk the audit graph the way an assessor would, and prove it lands.
#
#     profile  ->  component  ->  evidence href  ->  fetch  ->  verify  ->  CHAIN INTACT
#
# This is the claim the whole six-week build is making: that a stranger can
# confirm a control without asking anybody anything. So it should not be a
# paragraph in a README, it should be a script that exits non-zero when it stops
# being true.
#
# Every step reads from the OSCAL documents. Nothing about which controls exist,
# which bundle proves them, or who signed it is hardcoded here — pull the
# evidence URL out of the component definition, change nothing else, and this
# script follows it. That is what makes it a traversal rather than a re-enactment.
#
# The evidence is fetched over the network from the published URL, not read from
# the working tree, because "the file next to me verifies" is a much weaker claim
# than "the file a stranger downloads verifies".
#
# Usage:
#   ./traverse.sh                 # every control in the profile
#   ./traverse.sh sc-28           # one control
#   ./traverse.sh --offline       # verify the local copies instead of fetching
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OSCAL="$HERE/6week-challenge/week-6/oscal"
PROFILE="$OSCAL/profiles/grc-pipeline-controls/profile.json"
COMPONENT="$OSCAL/component-definitions/grc-pipeline/component-definition.json"
VERIFY="$HERE/6week-challenge/week-4/verify-evidence.sh"

OFFLINE=0
WANT=""
for arg in "$@"; do
  case "$arg" in
    --offline) OFFLINE=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) WANT="$arg" ;;
  esac
done

for f in "$PROFILE" "$COMPONENT" "$VERIFY"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
command -v jq >/dev/null || { echo "traverse.sh needs jq" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------------------"; }

# --- 1. PROFILE: what is in scope ------------------------------------------
# Written as a pipeline of plain `.["key"]` steps rather than the more compact
# `.imports[].["include-controls"]`. That compact form is accepted by jq 1.7 but
# is a syntax error in jq 1.6, which is what Debian 12 and Ubuntu 22.04 ship —
# so the tidier spelling worked on the author's Mac and produced an empty list
# everywhere else.
CONTROLS="$(jq -r '
  .profile.imports[]
  | .["include-controls"][]?
  | .["with-ids"][]?' "$PROFILE")"
CATALOG="$(jq -r '.profile.imports[0].href' "$PROFILE")"

bold "profile: $(jq -r '.profile.metadata.title' "$PROFILE")"
echo "  catalog:  $CATALOG"
echo "  in scope: $(echo "$CONTROLS" | tr '\n' ' ')"

# An empty selection is a broken profile, not an empty success. Without this the
# script walks zero controls, never enters the loop, never increments FAIL, and
# prints "TRAVERSAL COMPLETE — 0/0" with exit 0 — a green result that verified
# nothing, which is the exact failure this whole pipeline exists to prevent.
if [ -z "${CONTROLS//[[:space:]]/}" ]; then
  echo >&2
  echo "BROKEN GRAPH: the profile selects no controls." >&2
  echo "Either include-controls is empty, or jq could not read it — check that" >&2
  echo "\`jq -r '.profile.imports[] | .[\"include-controls\"][]?' $PROFILE\` returns rows." >&2
  exit 1
fi

if [ -n "$WANT" ]; then
  echo "$CONTROLS" | grep -qx "$WANT" || {
    echo >&2
    echo "control '$WANT' is not in the profile. The profile is the scope statement:" >&2
    echo "a control it does not select is a control this pipeline does not claim." >&2
    exit 2
  }
  CONTROLS="$WANT"
fi

PASS=0
FAIL=0

for CONTROL in $CONTROLS; do
  echo
  rule
  bold "control: ${CONTROL}"
  rule

  # --- 2. COMPONENT: how it is implemented ---------------------------------
  REQ="$(jq --arg c "$CONTROL" '
    .["component-definition"].components[]
    | .["control-implementations"][]
    | .["implemented-requirements"][]
    | select(.["control-id"] == $c)' "$COMPONENT")"

  if [ -z "$REQ" ]; then
    echo "  BROKEN GRAPH: the profile selects $CONTROL but no implemented-requirement"
    echo "  in the component definition covers it. The scope claims more than the"
    echo "  implementation states."
    FAIL=$((FAIL + 1))
    continue
  fi

  p() { echo "$REQ" | jq -r --arg n "$1" '[.props[]? | select(.name==$n) | .value] | join(", ")'; }

  echo "  resources:   $(p terraform-resource)"
  POLICY="$(p policy-package)"
  echo "  policy:      ${POLICY:-<none — see remarks>}"
  echo "  verified at: $(p verification-point)"

  # --- 3. EVIDENCE HREF ----------------------------------------------------
  # The fetchable copy (https) is what a stranger can reach; the s3:// copy is
  # the one nobody can delete. Take the first of each.
  BUNDLE_URL="$(echo "$REQ" | jq -r '[.links[]? | select(.rel=="evidence") | .href | select(startswith("http"))][0] // empty')"
  VAULT_URI="$(echo "$REQ" | jq -r '[.links[]? | select(.rel=="evidence") | .href | select(startswith("s3://"))][0] // empty')"

  if [ -z "$BUNDLE_URL" ]; then
    echo "  BROKEN GRAPH: no fetchable rel=\"evidence\" link on this requirement."
    FAIL=$((FAIL + 1))
    continue
  fi
  echo "  evidence:    $BUNDLE_URL"
  [ -n "$VAULT_URI" ] && echo "  vault:       $VAULT_URI"

  # The verifier pins are part of the claim, so they come out of the document
  # rather than out of this script's defaults. An unpinned cosign verify-blob
  # accepts a signature from anyone at all.
  ISSUER="$(p evidence-signer-issuer)"
  IDENTITY="$(p evidence-signer-identity)"
  echo "  signer:      ${IDENTITY:-<unpinned>}"
  echo "               via ${ISSUER:-<unpinned>}"

  if [ -z "$ISSUER" ] || [ -z "$IDENTITY" ]; then
    echo "  BROKEN GRAPH: the document does not say who signed this evidence, so"
    echo "  'verified' would mean 'signed by somebody'."
    FAIL=$((FAIL + 1))
    continue
  fi

  # --- 4. FETCH ------------------------------------------------------------
  NAME="$(basename "$BUNDLE_URL")"
  DEST="$TMP/$CONTROL"
  mkdir -p "$DEST"

  echo
  if [ "$OFFLINE" = "1" ]; then
    # Map the published URL back to the working tree. Only for use on a plane.
    REL="${BUNDLE_URL#*/6week-challenge/}"
    LOCAL="$HERE/6week-challenge/$REL"
    echo "  [offline] copying from the working tree: 6week-challenge/$REL"
    for ext in "" ".sha256" ".sig.bundle"; do
      cp "$LOCAL$ext" "$DEST/$NAME$ext" 2>/dev/null || {
        echo "  FETCH FAILED: no local $LOCAL$ext"; FAIL=$((FAIL + 1)); continue 2; }
    done
  else
    echo "  fetching the bundle, its sidecar and its signature from the published URL"
    OK=1
    for ext in "" ".sha256" ".sig.bundle"; do
      curl -fsSL --max-time 60 -o "$DEST/$NAME$ext" "$BUNDLE_URL$ext" || {
        echo "  FETCH FAILED: $BUNDLE_URL$ext did not resolve."
        echo "  An evidence link that 404s is an attestation that proves nothing."
        OK=0; break; }
    done
    [ "$OK" = "1" ] || { FAIL=$((FAIL + 1)); continue; }
  fi

  # --- 5. VERIFY -----------------------------------------------------------
  # Preservation is checked too when the s3 URI is present and AWS credentials
  # happen to be available. Without them the verifier says "skipped", which is
  # the honest answer: an unreadable vault is not a verified vault.
  VAULT_ENV=()
  if [ -n "$VAULT_URI" ] && command -v aws >/dev/null 2>&1 \
     && aws sts get-caller-identity >/dev/null 2>&1; then
    NOSCHEME="${VAULT_URI#s3://}"
    VAULT_ENV=(
      "EVIDENCE_VAULT_BUCKET=${NOSCHEME%%/*}"
      "EVIDENCE_VAULT_KEY=${NOSCHEME#*/}"
    )
  fi

  echo
  # ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": on bash before 4.4, expanding
  # an EMPTY array under `set -u` aborts with "unbound variable". That includes
  # the bash 3.2 macOS ships and some older container images. VAULT_ENV is empty
  # in exactly the common case — a reader with no AWS credentials — so the plain
  # form breaks the script for most of its audience. This form is correct on
  # every bash from 3.2 up.
  if env ${VAULT_ENV[@]+"${VAULT_ENV[@]}"} \
       EXPECT_ISSUER="$ISSUER" EXPECT_IDENTITY="$IDENTITY" \
       "$VERIFY" "$DEST/$NAME" 2>&1 | sed 's/^/  /'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
done

echo
rule
if [ "$FAIL" -eq 0 ]; then
  bold "TRAVERSAL COMPLETE — $PASS/$PASS control(s) walked from profile to verified evidence"
  exit 0
fi
bold "TRAVERSAL INCOMPLETE — $PASS passed, $FAIL failed"
exit 1
