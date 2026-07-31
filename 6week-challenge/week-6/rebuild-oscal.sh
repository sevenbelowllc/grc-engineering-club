#!/usr/bin/env bash
# rebuild-oscal.sh — regenerate every OSCAL document in this workspace, in order.
#
# Run this instead of running the generators by hand, because the documents are
# coupled and the coupling is easy to get wrong:
#
#   authoring/generate-documents.py mints fresh UUIDs on every run. The
#   assessment-results documents reference implemented-requirement UUIDs from the
#   component definition (finding.implementation-statement-uuid), so regenerating
#   the component alone leaves the results pointing at requirements that no
#   longer exist. The documents stay schema-VALID while the graph is broken,
#   which is the worst possible failure mode: trestle says yes and the traversal
#   says nothing.
#
# So: component first, results after, always. That is all this script enforces.
#
# NOT a CI step. CI validates the committed documents; it does not regenerate
# them. Regenerating in CI would mean the artifact under test is built by the
# same run that tests it, and every commit would churn every UUID.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PYTHON="${PYTHON:-python3}"
OSCAL="oscal"
CD="$OSCAL/component-definitions/grc-pipeline/component-definition.json"
AP_HREF="../../assessment-plans/grc-pipeline-assessment/assessment-plan.json"

PIN="1d97be7f0763223db7a42b805375c6302fd24e14"
RAW="https://raw.githubusercontent.com/sevenbelowllc/grc-engineering-club/$PIN/6week-challenge"
VAULT="s3://grc-challenge-evidence-vault-f11fcaca/manual/2026-07-26"

# The moment Rekor countersigned the week-4 evidence bundle — an independent,
# append-only timestamp for when the gate that produced those verdicts ran. Read
# it back out of the signature bundle rather than trusting this constant:
#   python3 -c 'import json,datetime;b=json.load(open("../week-4/evidence/evidence.tar.gz.sig.bundle"));\
#   print(datetime.datetime.fromtimestamp(int(b["verificationMaterial"]["tlogEntries"][0]["integratedTime"]),datetime.timezone.utc))'
GATE_RUN_AT="2026-07-22T01:16:40+00:00"

# Fixed so the negative control is reproducible. It is a demonstration artifact,
# not a record of a real gate run, and stamping it with the current time would
# make it churn on every rebuild for no informational gain.
NEGATIVE_AT="2026-07-26T19:45:00+00:00"

echo "==> 1/4  static documents (profile, component definition, assessment plan)"
"$PYTHON" "$OSCAL/authoring/generate-documents.py"

echo
echo "==> 2/4  assessment results from the signed gate run"
"$PYTHON" ./oscal-from-conftest.py \
  --conftest ../week-3/evidence/conftest-results.json \
  --component "$CD" \
  --plan-href "$AP_HREF" \
  --evidence "$RAW/week-4/evidence/evidence.tar.gz" \
  --evidence "$VAULT/evidence.tar.gz" \
  --assessed-at "$GATE_RUN_AT" \
  -o "$OSCAL/assessment-results/grc-gate-run/assessment-results.json"

echo
echo "==> 3/4  assessment results from the broken plan (negative control)"
"$PYTHON" ./oscal-from-conftest.py \
  --conftest evidence/conftest-results-broken-plan.json \
  --component "$CD" \
  --plan-href "$AP_HREF" \
  --evidence "$RAW/week-3/plan-broken.json" \
  --assessed-at "$NEGATIVE_AT" \
  --note "NEGATIVE CONTROL — not a production assessment. Generated from week-3/plan-broken.json, a Terraform plan with the encryption resources deliberately removed, to demonstrate that this converter emits not-satisfied when the gate denies. A pipeline that has only ever produced passing results has not been shown to be capable of producing a failing one." \
  -o "$OSCAL/assessment-results/broken-plan-negative-control/assessment-results.json"

echo
echo "==> 4/4  validate every model in the workspace"
( cd "$OSCAL" && trestle validate -a )

echo
echo "Rebuilt. Re-sign before committing:  ./sign-oscal.sh"
