#!/usr/bin/env bash
# plan-from-source.sh <terraform-dir> <output.json>
# plan-from-source.sh --write-hash <terraform-dir> <output.sha256>
#
# Turns Terraform source into plan JSON that conftest can evaluate, WITHOUT an
# AWS account.
#
# Why this exists. The gate evaluates `plan.json`, and `plan.json` was generated
# by hand once and committed. That makes the policy verdict a statement about a
# file, not about the source next to it: editing main.tf to allow public bucket
# access leaves `terraform validate` green (it only parses and type-checks) and
# leaves conftest green (it re-reads the same frozen fixture). Both required
# status checks pass and the change merges. Regenerating the plan from source on
# every run is what turns the verdict back into a statement about the code.
#
# Why it can run with no credentials. The AWS provider calls
# sts:GetCallerIdentity when it configures, so a plain `terraform plan` on a
# machine without credentials dies with InvalidClientTokenId. None of the
# resources here need an API call at plan time, though — there are no data
# sources, and with no state file a plan is all-creates. So the only thing
# standing between a reader and a fresh plan is provider credential validation,
# and that is switchable. This script copies the source to a temp directory and
# drops in an override that switches it off. The repo's promise in README.md is
# "Nothing needs an AWS account"; this keeps it.
#
# The override lives in a COPY, never in the working tree. Terraform merges any
# *_override.tf it finds, so writing one next to the real source would silently
# change what `terraform plan` means for everybody afterwards — including a
# `terraform apply`. A temp directory removed on exit cannot do that.
set -euo pipefail

# --- shared helpers ---------------------------------------------------------
# Byte-identical to the copies in week-4/verify-evidence.sh, week-5/
# sign-evidence.sh and week-6/sign-oscal.sh. See the note in
# week-4/verify-evidence.sh for why these are duplicated rather than sourced:
# each week directory has to stand alone. Change one, change all of them.

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

# --- source hash ------------------------------------------------------------
# One definition of "the hash of this Terraform source", used both to write the
# sidecar and to check it. Two definitions would drift and the check would start
# disagreeing with the generator for reasons nobody could reproduce.
#
# `LC_ALL=C ls` because the sort order of the file list is part of the hash, and
# a locale that collates differently would produce a different digest for
# identical bytes. Only *.tf: .terraform.lock.hcl pins provider versions, which
# matters to the plan but is not the source under review, and including it would
# make every routine provider bump look like a compliance change.
source_hash() {
  local dir="$1"
  [ -d "$dir" ] || fail "not a directory: $dir"
  ( export LC_ALL=C; cd "$dir" || exit 1; cat -- *.tf ) \
    | sha256_file /dev/stdin | awk '{print $1}'
}

if [ "${1:-}" = "--write-hash" ]; then
  SRC="${2:?usage: plan-from-source.sh --write-hash <terraform-dir> <output.sha256>}"
  OUT="${3:?usage: plan-from-source.sh --write-hash <terraform-dir> <output.sha256>}"
  source_hash "$SRC" > "$OUT"
  echo "wrote $OUT"
  exit 0
fi

SRC="${1:?usage: plan-from-source.sh <terraform-dir> <output.json>}"
OUT="${2:?usage: plan-from-source.sh <terraform-dir> <output.json>}"

[ -d "$SRC" ] || fail "not a directory: $SRC"
command -v terraform >/dev/null 2>&1 || fail "terraform not installed"

# Resolve the output path NOW, while the caller's working directory is still the
# current one. Everything below runs inside a temp directory that is deleted on
# exit, so a relative path resolved late would be written into the temp copy and
# taken away with it — the script would report success and leave no file.
case "$OUT" in
  /*) ;;
   *) OUT="$PWD/$OUT" ;;
esac

# The same three inputs CI passes (see grc-gate.yml, the grc-gate-oidc job) and
# the same three baked into the committed plan.json. They are not secrets — the
# build's required variables simply have no defaults, because a project name and
# an environment should be a deliberate choice rather than something you inherit.
# Overridable so a reader can plan their own naming without editing this file.
TF_VAR_project_name_="${PLAN_PROJECT_NAME:-grc-challenge}"
TF_VAR_environment_="${PLAN_ENVIRONMENT:-dev}"
TF_VAR_region_="${PLAN_REGION:-us-east-1}"

# A fresh temp directory means a fresh provider download unless the plugin cache
# is shared. Without this every run of verify-pipeline.sh re-fetches the AWS
# provider — around a minute and several hundred megabytes, for a check that
# otherwise takes three seconds. The cache location is overridable but defaults
# somewhere stable so the cost is paid once per machine, not once per run.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${TMPDIR:-/tmp}/grc-tf-plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$SRC"/*.tf "$WORK/" || fail "no .tf files in $SRC"
# The lock file travels too. Without it `terraform init` is free to resolve a
# different provider version than the one the repo pins, and a plan generated
# against a different provider is not evidence about this build.
#
# `if`, not `[ -f ... ] && cp ...`: under `set -e` a bare compound whose left
# side is false makes the whole statement non-zero and kills the script, so the
# short form would abort here on any source dir that has no lock file.
if [ -f "$SRC/.terraform.lock.hcl" ]; then
  cp "$SRC/.terraform.lock.hcl" "$WORK/"
fi

# zz_ prefix so it sorts last and is obvious in a directory listing if a future
# reader ever dumps the temp dir mid-run.
cat > "$WORK/zz_offline_override.tf" <<'OVERRIDE'
# Generated by plan-from-source.sh. Never written to the working tree.
#
# Switches off the four provider behaviours that reach the network at configure
# time. Each one is a lookup, not a safety check: none of them affect what
# resources the plan contains, which is the only thing the policies read.
provider "aws" {
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}
OVERRIDE

# Placeholder credentials passed explicitly rather than left to the ambient
# environment. The caller may well have real ones — verify-pipeline.sh's vault
# check needs them — and a plan run is a read of the account it is pointed at.
# This check is about the source, so it is pointed at nothing.
plan_env() {
  env AWS_ACCESS_KEY_ID=PLACEHOLDER_AWS_ACCESS_KEY_ID \
      AWS_SECRET_ACCESS_KEY=PLACEHOLDER_AWS_SECRET_ACCESS_KEY \
      AWS_SESSION_TOKEN= \
      AWS_PROFILE= \
      AWS_REGION="$TF_VAR_region_" \
      AWS_EC2_METADATA_DISABLED=true \
      "$@"
}

cd "$WORK"

# -backend=false: there is no backend block, and a plan for policy evaluation
# has no business touching remote state even if one were added later.
terraform init -backend=false -input=false -no-color >/dev/null 2>&1 \
  || fail "terraform init failed in the temp copy of $SRC"

plan_env terraform plan -out=tfplan -input=false -no-color \
  -var "project_name=$TF_VAR_project_name_" \
  -var "environment=$TF_VAR_environment_" \
  -var "region=$TF_VAR_region_" >/dev/null 2>&1 \
  || fail "terraform plan failed for $SRC"

terraform show -json tfplan > "$OUT" 2>/dev/null \
  || fail "terraform show -json failed for $SRC"

[ -s "$OUT" ] || fail "produced an empty plan JSON for $SRC"
