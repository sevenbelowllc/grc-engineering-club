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
# installed types ./verify-pipeline.sh and gets a verdict — no walkthrough,
# no screenshots, no author present.
#
# The verdict is PASS, FAIL, or INCOMPLETE. Only the author or CI holds
# credentials for the private evidence vault, so on any other machine the two
# vault checks report SKIP and the ceiling is 12 passed, 1 skipped —
# INCOMPLETE, not PASS. That is the design, not a defect: an unreadable vault
# is not a verified vault. The full 14-check PASS lives in the committed
# transcript at week-6/evidence/pipeline-verification.txt.
#
# Checks that cannot run in the current environment are reported as SKIP and
# named, never silently passed. A skipped check is a check nobody has done.
#
# Usage:
#   ./verify-pipeline.sh              # human output
#   ./verify-pipeline.sh --transcript # also write evidence/pipeline-verification.txt
# `set -uo pipefail`, deliberately without `-e`. Every other script here uses
# `-euo`; this one must not, because a failing check is the thing it exists to
# report. With `-e` the first FAIL would abort before the later checks ran, so
# the output would show one failure and silently hide any others.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CH="$HERE/6week-challenge"
TRANSCRIPT="$CH/week-6/evidence/pipeline-verification.txt"

# --transcript re-runs the script with output teed to a file, colour stripped.
# Re-exec rather than threading a flag through every printf: the transcript is
# then provably the same output a reader gets on their own terminal, because it
# is literally that output.
#
# The run is its own pipeline so that PIPESTATUS[0] is the script and nothing else.
# Three shapes that look equivalent are not:
#
#   { ...; "$0"; echo; echo "exit=$?"; } | ...   $? is the blank echo. Always 0.
#   exit "${PIPESTATUS[0]}"  on that group       the group's status is that same
#                                                echo. Always 0.
#   { "$0" || rc=$?; } | ...                     the group is the left side of a
#                                                pipeline, so it runs in a subshell
#                                                and rc never reaches the parent.
#
# All three record exit=0 for a failing run, which is the one thing a transcript
# of a compliance verifier must never do. Hence the header, the run and the footer
# as three separate commands, appending, with the status read off the run itself.
if [ "${1:-}" = "--transcript" ]; then
  mkdir -p "$(dirname "$TRANSCRIPT")"
  {
    echo "# verify-pipeline.sh — every eligibility check for the six-week build."
    echo "# Captured $(date -u +%Y-%m-%dT%H:%M:%SZ). Reproduce: ./verify-pipeline.sh"
    echo
  } | tee "$TRANSCRIPT"

  "$0" 2>&1 | sed $'s/\033\\[[0-9;]*m//g' | tee -a "$TRANSCRIPT"
  rc="${PIPESTATUS[0]}"

  { echo; echo "exit=$rc"; } | tee -a "$TRANSCRIPT"
  exit "$rc"
fi

# --- reporting vocabulary ---------------------------------------------------
# Byte-identical to the copy in traverse.sh. Each script carries the subset it
# uses; every definition below is identical wherever it appears. Change one,
# change the other.
#
#   c_bold c_green c_red c_grey   inline colourisers, no trailing newline
#   rule                          a horizontal rule
#   title  section                a bold line; a bold line preceded by a blank
#   ok  bad  skip                 one result line AND the counter that goes with it
#   need                          is this tool on PATH
#
# The counters live inside ok/bad/skip deliberately. A reporting helper that
# prints a failure without recording it is how a closing summary ends up
# disagreeing with the body of output above it — and the summary is the part
# people actually read.
#
# The closing message is NOT shared. Both scripts build it from `rule`, `c_bold`
# and these counters, but each says its own thing, because "TRAVERSAL COMPLETE —
# 4/4 control(s) walked" is quoted verbatim in the README, the submission and
# the committed evidence transcripts. Unifying the words would churn documented
# output for no gain; unifying the vocabulary that produces them is the point.
PASS=0; FAIL=0; SKIP=0
FAILED=()

c_bold() { printf '\033[1m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_red() { printf '\033[31m%s\033[0m' "$*"; }
c_grey() { printf '\033[90m%s\033[0m' "$*"; }

rule() { printf '%s\n' "------------------------------------------------------------------------"; }
title() { printf '%s\n' "$(c_bold "$*")"; }
section() { printf '\n%s\n' "$(c_bold "$*")"; }

ok() { printf '  [%s] %s\n' "$(c_green PASS)" "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [%s] %s\n' "$(c_red FAIL)" "$1"; FAIL=$((FAIL + 1)); FAILED+=("$1"); }
skip() { printf '  [%s] %s\n' "$(c_grey SKIP)" "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$(c_grey "$2")"; SKIP=$((SKIP + 1)); }

need() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
section "1. terraform validate — the infrastructure parses and type-checks"
# ---------------------------------------------------------------------------
if ! need terraform; then
  skip "terraform validate" "terraform is not installed"
else
  # This check does NOT run `terraform init`, and that is the point.
  #
  # `terraform validate` needs provider schemas, so it needs an initialised
  # directory — and the obvious way to get one is to init on the reader's behalf.
  # That is the wrong trade. init downloads several hundred megabytes of AWS
  # provider, per directory, against a registry the reader may not be able to
  # reach, to establish the weakest claim in this file: that the HCL parses.
  # Nobody running someone else's verifier has agreed to that.
  #
  # It is also a category error in the reporting. When the download failed, this
  # printed `[FAIL] week-1/solution` — telling a reviewer the infrastructure is
  # broken when the true statement is "this machine has not fetched a provider".
  # An uninitialised working directory is a fact about the machine, not a defect
  # in the repository, and the same reasoning that makes a missing cosign a SKIP
  # in section 6 makes this one too.
  #
  # Anyone who wants the check runs `terraform init` themselves and re-runs.
  for d in week-1/solution week-3/terraform week-5/terraform week-6/terraform; do
    # A directory that is missing altogether is a defect in the repository, not
    # a fact about this machine — the opposite of the uninitialised case below.
    # It used to be `continue`, which made the check disappear: not PASS, not
    # FAIL, not SKIP, and the total quietly dropped from 14 to 13. A check that
    # vanishes is worse than one that fails.
    if [ ! -d "$CH/$d" ]; then
      bad "$d — directory is missing from the repository"
    elif [ ! -d "$CH/$d/.terraform" ]; then
      skip "$d" "not initialised on this machine — run 'terraform init' in 6week-challenge/$d to include this check"
    elif out="$( cd "$CH/$d" && terraform validate -no-color 2>&1 )"; then
      ok "$d"
    else
      bad "$d — $(echo "$out" | head -3 | tr '\n' ' ')"
    fi
  done
fi

# ---------------------------------------------------------------------------
section "2. conftest — the policy gate denies what it is supposed to deny"
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
  # A non-zero exit alone is not a denial. conftest also exits 1 for a missing
  # plan file and for a .rego that fails to parse — verified, both exit 1 —
  # and reporting either as "the gate denied it" would pass the negative
  # control on a broken toolchain. So require a named rule in the output, the
  # same way the fresh-plan check below names what fired.
  if out="$( cd "$CH/week-3" && conftest test --all-namespaces -p policies plan-broken.json 2>&1 )"; then
    bad "broken plan PASSED the gate — the policy is not enforcing"
  else
    rules="$(echo "$out" | grep -oE 'compliance\.[a-z0-9_]+' | sort -u | tr '\n' ' ')"
    if [ -n "$rules" ]; then
      ok "broken plan is denied by the gate — ${rules% }"
    else
      bad "conftest failed on the broken plan without naming a rule — a tooling error is not a denial: $(echo "$out" | grep -v '^$' | tail -2 | tr '\n' ' ')"
    fi
  fi

  # Both checks above evaluate a plan that was generated once, by hand, and
  # committed. That makes them a statement about two files rather than about the
  # infrastructure next to them. Remove the public access block from
  # week-3/terraform/main.tf and nothing here notices: `terraform validate` in
  # section 1 only parses and type-checks, and conftest re-reads the same frozen
  # fixture. Both required status checks go green and the change merges.
  #
  # So: regenerate the plan from the source as it stands right now and run the
  # same policies against that. plan-from-source.sh does it in a temp copy with
  # provider credential validation switched off, which needs no AWS account and
  # keeps README.md's "Nothing needs an AWS account" true.
  PLAN_SRC="$CH/week-3/plan-from-source.sh"
  TF_SRC="$CH/week-3/terraform"
  # Reuse the providers week-3/terraform already has rather than fetching a
  # second copy. plan-from-source.sh inits a temp directory, and .terraform/
  # providers happens to use the exact layout TF_PLUGIN_CACHE_DIR expects, so
  # pointing one at the other makes that init resolve locally and download
  # nothing. Without this, running the verifier costs a fresh provider download
  # on top of whatever section 1 already needed.
  if [ -d "$TF_SRC/.terraform/providers" ]; then
    export TF_PLUGIN_CACHE_DIR="$TF_SRC/.terraform/providers"
  fi
  if ! need terraform; then
    skip "current source produces a compliant plan" "terraform is not installed, so the plan cannot be regenerated"
  elif [ ! -d "$TF_SRC/.terraform" ]; then
    # Same rule as section 1: this check will not initialise someone else's
    # working directory to make itself runnable.
    skip "current source produces a compliant plan" "week-3/terraform is not initialised — run 'terraform init' there to include this check"
  elif [ ! -x "$PLAN_SRC" ]; then
    skip "current source produces a compliant plan" "plan-from-source.sh not found or not executable"
  else
    # A directory, so the file can be named plan.json. conftest picks its parser
    # from the extension, and `mktemp -t grc-fresh-plan` produces a random suffix
    # like .4JmDlwDq5s — which conftest reads as the parser name and rejects with
    # "unknown parser". The failure looks exactly like a policy failure.
    FRESHDIR="$(mktemp -d)"
    FRESH="$FRESHDIR/plan.json"
    if ! out="$("$PLAN_SRC" "$TF_SRC" "$FRESH" 2>&1)"; then
      bad "current source produces a compliant plan — $(echo "$out" | tail -2 | tr '\n' ' ')"
    elif out="$( cd "$CH/week-3" && conftest test --all-namespaces -p policies "$FRESH" 2>&1 )"; then
      ok "current terraform source produces a compliant plan"
    else
      # Name the rule that fired: "the plan is non-compliant" sends a reader
      # through three namespaces, "compliance.ac3_aws" sends them to one. Fall
      # back to the raw output when nothing matches, because conftest also exits
      # non-zero for reasons that are not policy failures at all, and a reason
      # this check cannot name is still a reason the reader needs to see.
      rules="$(echo "$out" | grep -oE 'compliance\.[a-z0-9_]+' | sort -u | tr '\n' ' ')"
      bad "current terraform source produces a NON-compliant plan — ${rules:-$(echo "$out" | grep -v '^$' | tail -2 | tr '\n' ' ')}"
    fi
    rm -rf "$FRESHDIR"
  fi

  # The committed plan.json is not just a fixture — it is signed evidence, inside
  # week-4/evidence/evidence.tar.gz. The check above proves the source is
  # compliant; this one proves the committed evidence was generated from that
  # same source. A plan.json left behind by an edited main.tf is a bundle that
  # attests to infrastructure nobody is running.
  #
  # Regenerate with:
  #   week-3/plan-from-source.sh --write-hash week-3/terraform week-3/plan-source.sha256
  # and re-sign the week-4 bundle, because changing the source invalidates both.
  #
  # Deliberately NOT gated on terraform. --write-hash only reads the .tf files
  # and shells out to sha256sum/shasum, so this still answers on a machine that
  # cannot generate a plan — which is exactly the machine most likely to be
  # looking at a stale fixture.
  HASH_FILE="$CH/week-3/plan-source.sha256"
  if [ ! -x "$PLAN_SRC" ]; then
    skip "plan.json matches the terraform source" "plan-from-source.sh not found or not executable"
  elif [ ! -f "$HASH_FILE" ]; then
    skip "plan.json matches the terraform source" "no plan-source.sha256 recorded"
  else
    expected="$(cat "$HASH_FILE")"
    actual="$("$PLAN_SRC" --write-hash "$TF_SRC" /dev/stdout 2>/dev/null | head -1)"
    if [ "$expected" = "$actual" ]; then
      ok "committed plan.json matches the terraform source it came from"
    else
      bad "committed plan.json is STALE — week-3/terraform has changed since it was generated (and since the week-4 bundle was signed)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
section "3. trestle validate — the OSCAL documents are schema-valid"
# ---------------------------------------------------------------------------
if ! need trestle; then
  skip "trestle validate" "trestle is not installed (pip install compliance-trestle)"
else
  if out="$( cd "$CH/week-6/oscal" && trestle validate -a 2>&1 )"; then
    n="$(echo "$out" | grep -c '^VALID')"
    # trestle validate -a exits 0 on an empty workspace — verified — so the
    # exit code alone would let this print "all 0 OSCAL documents VALID" over
    # a directory that validated nothing. The build has 5 documents; a floor
    # rather than an exact match, so adding a sixth does not break the verifier
    # while a gutted workspace fails loudly.
    if [ "$n" -ge 5 ]; then
      ok "all $n OSCAL documents VALID"
    else
      bad "trestle exited 0 but only $n document(s) validated — expected at least 5; an empty workspace validates vacuously"
    fi
  else
    bad "trestle validate — $(echo "$out" | grep -v '^VALID' | head -2 | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------------------
section "4. cosign verify — the evidence is authentic and intact"
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
section "5. vault preservation — the evidence cannot be deleted"
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
section "6. traversal — profile to verified evidence, following only the documents"
# ---------------------------------------------------------------------------
# cosign is gated here, not left to fail inside traverse.sh. The traversal ends in
# the same verify-evidence.sh that check 4 runs, so a machine without cosign cannot
# complete either one — and check 4 already calls that SKIP. Without this guard the
# same missing binary reports SKIP at check 4 and FAIL at check 6, and the FAIL
# takes the whole run to PIPELINE FAIL on a machine where nothing is actually wrong.
#
# The gate belongs here rather than in verify-evidence.sh, which fails loudly on a
# missing cosign on purpose (see the comment above its command -v). A verifier that
# shrugs when its verifier is absent is the bug; a caller that declines to claim a
# result it cannot obtain is not.
if [ ! -x "$HERE/traverse.sh" ]; then
  skip "traversal" "traverse.sh not found or not executable"
elif ! need jq; then
  skip "traversal" "traverse.sh needs jq"
elif ! need cosign; then
  skip "traversal" "traverse.sh ends in a cosign verify-blob; cosign is not installed"
else
  if out="$("$HERE/traverse.sh" 2>&1)"; then
    # traverse.sh emits ANSI for its own terminal output; strip it before quoting.
    ok "$(echo "$out" | grep 'TRAVERSAL COMPLETE' | sed $'s/\033\\[[0-9;]*m//g; s/.*— //')"
  else
    bad "traversal — $(echo "$out" | grep -E 'BROKEN GRAPH|FETCH FAILED|FAIL:' | head -2 | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------------------
echo
rule
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
echo

if [ "$FAIL" -gt 0 ]; then
  title "PIPELINE FAIL"
  # ${arr[@]+"${arr[@]}"} — see traverse.sh: expanding an empty array under
  # `set -u` aborts on bash before 4.4. FAILED is empty on the happy path.
  for c in ${FAILED[@]+"${FAILED[@]}"}; do echo "  - $c"; done
  exit 1
fi

# A skipped check is not a passing check, and the word in the last line is the
# part people quote. On a machine with none of the tools installed this file used
# to print "PIPELINE PASS (with 9 check(s) skipped)" over a body reading
# "0 passed, 0 failed" — a pass verdict for a run that verified nothing. That is
# the exact shape of failure this repository exists to argue against, sitting in
# its own summary line.
#
# INCOMPLETE rather than FAIL, because nothing here is broken: the reader is
# missing tools, not looking at broken infrastructure. And exit 0 rather than 1,
# because the exit code answers "is something wrong with this repository?" and
# the honest answer is still no. CI does not rely on this code — it parses the
# counts line above and fails on any non-zero skip (.github/workflows/grc-gate.yml).
if [ "$SKIP" -gt 0 ]; then
  if [ "$PASS" -eq 0 ]; then
    title "PIPELINE INCOMPLETE — nothing was verified on this machine"
  else
    title "PIPELINE INCOMPLETE — $PASS check(s) passed, $SKIP could not run"
  fi
  printf '%s\n' "A skipped check is a check nobody has done. This run did not establish the claim."
  echo
  printf '%s\n' "Two full runs, every check executed, are committed and readable without installing anything:"
  printf '%s\n' "  6week-challenge/week-6/evidence/pipeline-verification.txt        (macOS)"
  printf '%s\n' "  6week-challenge/week-6/evidence/pipeline-verification-linux.txt  (Linux container)"
  printf '%s\n' "and .github/workflows/grc-gate.yml runs this same command on every pull request"
  printf '%s\n' "with the full toolchain, failing the build if even one check skips."
  exit 0
fi

title "PIPELINE PASS — every check ran and every check passed"
