# Week 4 Evidence Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sign the week-3 gate's evidence with Cosign keyless so anyone can prove it is authentic and untouched, and ship a `verify-evidence.sh` whose tamper test breaks on a single changed byte.

**Architecture:** Add a Cosign keyless signing step to the live root `grc-gate.yml` (decoupling gate execution from the verdict so a failed run is still signed), fill in `verify-evidence.sh` with integrity → authenticity → preservation checks, exercise it locally to produce tamper-test evidence, and ship a dormant S3 Object Lock vault for the preservation stretch.

**Tech Stack:** Cosign (Sigstore keyless), GitHub Actions, bash, Conftest (existing), Terraform + AWS S3 Object Lock (dormant stretch).

## Global Constraints

- **Repo:** `sevenbelowllc/grc-engineering-club`; work on branch `week4-evidence-signing`.
- **Live workflow:** `.github/workflows/grc-gate.yml` at repo root is the ONLY gate that triggers. The nested `6week-challenge/week3/week-3/.github/workflows/grc-gate.yml` copy is reference-only — never modify it.
- **Existing workflow env:** `CONFTEST_VERSION: "0.68.2"`, `WEEK3_DIR: 6week-challenge/week3`.
- **Pin versions, never `latest`** — reproducibility is the whole point (matches week 3's Conftest pin). Use `sigstore/cosign-installer@v3` with an explicit `cosign-release`.
- **Fail closed:** after decoupling, the gate must still end red on a policy failure. The final job step is the single source of the pass/fail decision.
- **id-token: write** must be granted at job level, or `cosign sign-blob` cannot mint its OIDC token.
- **Keyless only** — no long-lived signing key is ever generated, stored, or committed.
- **Naming convention:** bundle `evidence.tar.gz`, sidecar `evidence.tar.gz.sha256`, signature `evidence.tar.gz.sig.bundle`. Evidence screenshots follow `GRCChallenge-week4-*.png`.
- **Do NOT commit** `6week-challenge/week4/week4-overview.txt` (paywalled brief; matches week-3 commit `d8671bf`).
- **OIDC issuer (CI):** `https://token.actions.githubusercontent.com`. **OIDC issuer (local Sigstore browser flow):** `https://oauth2.sigstore.dev/auth`.
- **Commit trailer:** end every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

| Path | Responsibility |
|---|---|
| `6week-challenge/week4/verify-evidence.sh` | The verifier — three custody checks, prints `CHAIN INTACT` |
| `.github/workflows/grc-gate.yml` | Live gate — add id-token perm, decouple verdict, sign, enforce, upload, dormant vault upload |
| `6week-challenge/week4/vault/vault.tf` | Dormant S3 Object Lock vault (stretch) |
| `6week-challenge/week4/vault/README.md` | Vault apply/verify/teardown runbook |
| `6week-challenge/week4/evidence/` | Committed bundle + sidecar + sig.bundle + tamper-test logs |
| `6week-challenge/week4/SUBMISSION.md` | Portfolio writeup |
| `6week-challenge/week4/README.md` | Starter README (commit as-is with implementation) |

---

### Task 1: Implement `verify-evidence.sh`

**Files:**
- Modify: `6week-challenge/week4/verify-evidence.sh` (fill in the skeleton)
- Test: manual — a scratch bundle under the session scratchpad

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: CLI `verify-evidence.sh <bundle.tar.gz>`. Reads sidecar `<bundle>.sha256` and signature `<bundle>.sig.bundle` by convention. Honors env overrides: `EXPECT_ISSUER`, `EXPECT_IDENTITY` (regexp), `EVIDENCE_VAULT_BUCKET`, `EVIDENCE_VAULT_KEY`. Exit 0 + prints `CHAIN INTACT` only when all executed checks pass; non-zero otherwise.

- [ ] **Step 1: Write the script**

Replace the body of `6week-challenge/week4/verify-evidence.sh` (keep the shebang and the `set -euo pipefail` / `BUNDLE=` lines) with:

```bash
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

cosign verify-blob \
  --bundle "$SIGBUNDLE" \
  --certificate-oidc-issuer "$EXPECT_ISSUER" \
  --certificate-identity-regexp "$EXPECT_IDENTITY" \
  "$BUNDLE" >/dev/null 2>&1 \
  || fail "authenticity: cosign verify-blob rejected the signature/identity"
echo "authenticity: OK  (issuer=$EXPECT_ISSUER)"

# --- 3. PRESERVATION (stretch, dormant unless a vault is configured) --------
if [ -n "${EVIDENCE_VAULT_BUCKET:-}" ] && [ -n "${EVIDENCE_VAULT_KEY:-}" ]; then
  RETAIN="$(aws s3api get-object-retention \
    --bucket "$EVIDENCE_VAULT_BUCKET" --key "$EVIDENCE_VAULT_KEY" \
    --query 'Retention.RetainUntilDate' --output text)"
  NOW_EPOCH="$(date -u +%s)"
  RETAIN_EPOCH="$(date -u -d "$RETAIN" +%s 2>/dev/null || date -u -jf '%Y-%m-%dT%H:%M:%S%z' "${RETAIN%%.*}+0000" +%s)"
  [ "$RETAIN_EPOCH" -gt "$NOW_EPOCH" ] || fail "preservation: retention $RETAIN is not in the future"
  echo "preservation: OK  (locked until $RETAIN)"
else
  echo "preservation: skipped (no vault configured)"
fi

echo "CHAIN INTACT"
```

- [ ] **Step 2: Syntax + integrity-path check (no signing needed)**

Build a scratch bundle, confirm a valid bundle passes integrity and a tampered one fails. cosign is not yet installed, so this run stops at the authenticity check on the good bundle — that is expected here; we only assert the integrity behavior.

```bash
SP=/private/tmp/claude-501/-Users-pollucts-workdir-grc-engineering-club/63818727-8005-44ae-b5ae-63260abdafe4/scratchpad
bash -n 6week-challenge/week4/verify-evidence.sh && echo "syntax OK"
mkdir -p "$SP/ev/evidence" && echo '{"demo":true}' > "$SP/ev/evidence/conftest-results.json"
tar -czf "$SP/ev/evidence.tar.gz" -C "$SP/ev" evidence
shasum -a 256 "$SP/ev/evidence.tar.gz" > "$SP/ev/evidence.tar.gz.sha256"
cp "$SP/ev/evidence.tar.gz" "$SP/ev/tampered.tar.gz"; echo junk >> "$SP/ev/tampered.tar.gz"
cp "$SP/ev/evidence.tar.gz.sha256" "$SP/ev/tampered.tar.gz.sha256" 2>/dev/null || true
# integrity must FAIL on the tampered copy (sidecar still names original hash):
cp "$SP/ev/evidence.tar.gz.sha256" "$SP/ev/tampered.tar.gz.sha256"
6week-challenge/week4/verify-evidence.sh "$SP/ev/tampered.tar.gz" ; echo "exit=$?"
```

Expected: `syntax OK`; the tampered run prints `FAIL: integrity: sha256 mismatch...` and a non-zero exit (the `; echo exit=` shows a non-zero code, or the shell aborts before it — either way integrity failed). The good bundle would print `integrity: OK` then fail at `cosign not installed` — that is fine for this step.

- [ ] **Step 3: Commit**

```bash
git add 6week-challenge/week4/verify-evidence.sh 6week-challenge/week4/README.md 6week-challenge/week4/.gitignore 2>/dev/null; \
git add 6week-challenge/week4/verify-evidence.sh 6week-challenge/week4/README.md
git commit -m "week4: implement verify-evidence.sh (integrity, authenticity, preservation)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add the Cosign signing step to the live gate

**Files:**
- Modify: `.github/workflows/grc-gate.yml` (the `grc-gate` job only)

**Interfaces:**
- Consumes: existing env `WEEK3_DIR`, existing "Run policy gate" step (id `gate`), existing `if: always()` upload and PR-comment steps.
- Produces: build artifact `grc-gate-evidence` now also contains `evidence.tar.gz`, `evidence.tar.gz.sha256`, `evidence.tar.gz.sig.bundle`. Step output `steps.gate.outputs.gate` ∈ {`pass`,`fail`}. Job ends red iff `gate == fail`.

- [ ] **Step 1: Add `id-token: write` at job level**

In `.github/workflows/grc-gate.yml`, under `jobs.grc-gate`, add a job-scoped permissions block (the workflow-level block stays for other jobs):

```yaml
  grc-gate:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      id-token: write   # required so cosign can mint its keyless OIDC token
    steps:
```

- [ ] **Step 2: Decouple the gate verdict from execution**

Replace the `run:` body of the existing "Run policy gate" step (id `gate`) so it records the verdict instead of failing:

```yaml
      - name: Run policy gate
        id: gate
        run: |
          set -o pipefail
          mkdir -p "${WEEK3_DIR}/evidence"
          if conftest test "${WEEK3_DIR}/plan.json" \
               --policy "${WEEK3_DIR}/policies" \
               --namespace compliance.sc28_aws \
               --namespace compliance.ac3_aws \
               --namespace compliance.cm6_aws \
               --output json \
               | tee "${WEEK3_DIR}/evidence/conftest-results.json"; then
            echo "gate=pass" >> "$GITHUB_OUTPUT"
          else
            echo "gate=fail" >> "$GITHUB_OUTPUT"
          fi
```

- [ ] **Step 3: Add sign steps after the gate, before the upload**

Insert these steps immediately after the "Run policy gate" step:

```yaml
      - name: Install Cosign
        uses: sigstore/cosign-installer@v3
        with:
          cosign-release: 'v2.4.1'

      - name: Bundle, hash, and sign the evidence
        run: |
          set -euo pipefail
          tar -czf "${WEEK3_DIR}/evidence.tar.gz" -C "${WEEK3_DIR}" evidence
          sha256sum "${WEEK3_DIR}/evidence.tar.gz" \
            | awk '{print $1}' > "${WEEK3_DIR}/evidence.tar.gz.sha256"
          cosign sign-blob --yes \
            --bundle "${WEEK3_DIR}/evidence.tar.gz.sig.bundle" \
            "${WEEK3_DIR}/evidence.tar.gz"
```

- [ ] **Step 4: Extend the upload to include the signed artifacts**

Modify the existing "Upload evidence" step's `path:` to a multi-line list (keep `if: always()` and `if-no-files-found: error`):

```yaml
      - name: Upload evidence
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: grc-gate-evidence
          path: |
            ${{ env.WEEK3_DIR }}/evidence/
            ${{ env.WEEK3_DIR }}/evidence.tar.gz
            ${{ env.WEEK3_DIR }}/evidence.tar.gz.sha256
            ${{ env.WEEK3_DIR }}/evidence.tar.gz.sig.bundle
          if-no-files-found: error
```

- [ ] **Step 5: Add the final enforce step (single source of pass/fail)**

Add this as the LAST step of the `grc-gate` job, after the PR-comment step:

```yaml
      - name: Enforce gate verdict
        if: always()
        run: |
          if [ "${{ steps.gate.outputs.gate }}" != "pass" ]; then
            echo "A control failed — gate is red (evidence was signed and uploaded first)."
            exit 1
          fi
          echo "All controls passed."
```

- [ ] **Step 6: Lint the workflow**

```bash
command -v actionlint >/dev/null 2>&1 && actionlint .github/workflows/grc-gate.yml || \
  docker run --rm -v "$(pwd)":/repo -w /repo rhysd/actionlint:latest -color .github/workflows/grc-gate.yml || \
  python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/grc-gate.yml')); print('yaml OK')"
```

Expected: no errors (either `actionlint` clean, or the fallback `yaml OK`).

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/grc-gate.yml
git commit -m "week4: sign gate evidence with Cosign keyless; decouple verdict so failures are signed too

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Local sign + tamper test (produce the deliverable evidence)

**Files:**
- Create: `6week-challenge/week4/evidence/local-verify-pass.txt`
- Create: `6week-challenge/week4/evidence/local-verify-tamper-fail.txt`
- Create: `6week-challenge/week4/evidence/evidence.tar.gz`, `.sha256`, `.sig.bundle`

**Interfaces:**
- Consumes: `verify-evidence.sh` from Task 1.
- Produces: committed locally-signed bundle + two captured verification logs (pass and tamper-fail) that the SUBMISSION references. Note: local signer identity is `truevail@sevenbelow.com` via issuer `https://oauth2.sigstore.dev/auth`.

- [ ] **Step 1: Install cosign**

```bash
brew install cosign && cosign version | head -1
```

Expected: a `GitVersion:` line (cosign v2.x).

- [ ] **Step 2: Stage a real evidence bundle from current gate output**

```bash
cd 6week-challenge/week4
mkdir -p stage/evidence
# use the same plan the CI gate evaluates + a fresh conftest result
cp ../week3/plan.json stage/evidence/plan.json
conftest test ../week3/plan.json --policy ../week3/policies \
  --namespace compliance.sc28_aws --namespace compliance.ac3_aws --namespace compliance.cm6_aws \
  --output json | tee stage/evidence/conftest-results.json || true
tar -czf evidence/evidence.tar.gz -C stage evidence
shasum -a 256 evidence/evidence.tar.gz | awk '{print $1}' > evidence/evidence.tar.gz.sha256
cd ../..
```

Expected: `evidence/evidence.tar.gz` and `.sha256` exist. (`conftest` may or may not be installed locally; if missing, `brew install conftest` first. The `|| true` keeps a policy failure from aborting staging.)

- [ ] **Step 3: USER runs the interactive keyless sign**

This step opens a browser for the one-time identity check and can only be done by the user. Ask the user to run, via the `!` prefix in the prompt:

```
! cd 6week-challenge/week4 && cosign sign-blob --yes --bundle evidence/evidence.tar.gz.sig.bundle evidence/evidence.tar.gz
```

Expected: browser prompts, user authenticates as `truevail@sevenbelow.com`, `evidence/evidence.tar.gz.sig.bundle` is written.

- [ ] **Step 4: Verify the good bundle (local pins) → CHAIN INTACT**

```bash
cd 6week-challenge/week4
EXPECT_ISSUER='https://oauth2.sigstore.dev/auth' \
EXPECT_IDENTITY='^truevail@sevenbelow\.com$' \
  ./verify-evidence.sh evidence/evidence.tar.gz | tee evidence/local-verify-pass.txt
cd ../..
```

Expected: `integrity: OK`, `authenticity: OK`, `preservation: skipped`, `CHAIN INTACT`. (If verify races the transparency log, wait ~2s and re-run.)

- [ ] **Step 5: Tamper test → fails on integrity**

```bash
cd 6week-challenge/week4
cp evidence/evidence.tar.gz /tmp/tampered.tar.gz
cp evidence/evidence.tar.gz.sha256 /tmp/tampered.tar.gz.sha256
cp evidence/evidence.tar.gz.sig.bundle /tmp/tampered.tar.gz.sig.bundle
echo "junk" >> /tmp/tampered.tar.gz
EXPECT_ISSUER='https://oauth2.sigstore.dev/auth' \
EXPECT_IDENTITY='^truevail@sevenbelow\.com$' \
  ./verify-evidence.sh /tmp/tampered.tar.gz 2>&1 | tee evidence/local-verify-tamper-fail.txt; \
  echo "exit=${PIPESTATUS[0]}" | tee -a evidence/local-verify-tamper-fail.txt
cd ../..
```

Expected: `FAIL: integrity: sha256 mismatch (bundle was modified)` and `exit=1`.

- [ ] **Step 6: User screenshots both runs**

Ask the user to screenshot the pass run beside the tamper-fail run and save as `6week-challenge/week4/evidence/GRCChallenge-week4-tamper-test.png` (and any split parts `-p1/-p2`).

- [ ] **Step 7: Commit the evidence**

```bash
rm -rf 6week-challenge/week4/stage
git add 6week-challenge/week4/evidence/
git commit -m "week4: locally-signed evidence bundle + tamper-test logs (integrity breaks on one byte)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Dormant immutable vault (stretch)

**Files:**
- Create: `6week-challenge/week4/vault/vault.tf`
- Create: `6week-challenge/week4/vault/README.md`
- Modify: `.github/workflows/grc-gate.yml` (add one dormant upload step)

**Interfaces:**
- Consumes: the signed bundle + sidecar from Task 2's job.
- Produces: Terraform for an Object-Lock S3 bucket + scoped write policy; a workflow step gated on repo var `EVIDENCE_VAULT_BUCKET` that stays skipped until set. `verify-evidence.sh` Check 3 already reads `EVIDENCE_VAULT_BUCKET`/`EVIDENCE_VAULT_KEY`.

- [ ] **Step 1: Write `vault.tf`**

```hcl
# Dormant immutable evidence vault: an S3 bucket that even its owner cannot
# overwrite or delete before the retention window expires. Apply only for the
# preservation stretch; tear down the same day (pennies). Nothing here runs in
# CI until you set the EVIDENCE_VAULT_BUCKET repo variable to this bucket name.
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "region"      { type = string, default = "us-east-1" }
variable "bucket_name" { type = string }
variable "pipeline_role_arn" {
  type        = string
  description = "ARN of the GitHub OIDC role allowed to write the vault (week3 gate role)."
}

provider "aws" { region = var.region }

resource "aws_s3_bucket" "vault" {
  bucket              = var.bucket_name
  object_lock_enabled = true   # must be set at creation; cannot be added later
  tags = {
    project     = "grc-challenge"
    environment = "dev"
    owner       = "grc-eng-club"
    data-class  = "evidence"
  }
}

resource "aws_s3_bucket_versioning" "vault" {
  bucket = aws_s3_bucket.vault.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_object_lock_configuration" "vault" {
  bucket = aws_s3_bucket.vault.id
  rule {
    default_retention {
      mode = "COMPLIANCE"   # even root cannot shorten or delete before expiry
      days = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "vault" {
  bucket                  = aws_s3_bucket.vault.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "vault_write" {
  statement {
    sid       = "PipelinePutOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.vault.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [var.pipeline_role_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "vault" {
  bucket = aws_s3_bucket.vault.id
  policy = data.aws_iam_policy_document.vault_write.json
}

output "bucket_name" { value = aws_s3_bucket.vault.id }
```

- [ ] **Step 2: `terraform validate`**

```bash
cd 6week-challenge/week4/vault && terraform init -backend=false >/dev/null && terraform validate && cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Write `vault/README.md`**

```markdown
# Stretch: the immutable evidence vault

True preservation means the signed bundle cannot be overwritten or deleted —
even by you — until its retention window expires. This is a **dormant** stretch:
nothing runs in CI until you set the `EVIDENCE_VAULT_BUCKET` repo variable.

## Apply (pennies, tear down same day)

```bash
cd 6week-challenge/week4/vault
terraform init
terraform apply \
  -var "bucket_name=grc-evidence-vault-$(date +%s)" \
  -var "pipeline_role_arn=<your week3 gate role ARN>"
```

## Push one bundle and verify preservation

```bash
aws s3api put-object --bucket "$BUCKET" --key run-1/evidence.tar.gz \
  --body 6week-challenge/week4/evidence/evidence.tar.gz
EVIDENCE_VAULT_BUCKET="$BUCKET" EVIDENCE_VAULT_KEY=run-1/evidence.tar.gz \
  ./6week-challenge/week4/verify-evidence.sh 6week-challenge/week4/evidence/evidence.tar.gz
```

## The overwrite test (the point)

```bash
# Object Lock in COMPLIANCE mode refuses this until retention expires:
aws s3api put-object --bucket "$BUCKET" --key run-1/evidence.tar.gz --body /tmp/tampered.tar.gz
# -> AccessDenied / operation blocked by object lock retention
```

A tampered bundle has nowhere to live except a laptop. The vault stays clean.

## Teardown

```bash
# Object Lock blocks deletes until retention (1 day) expires. Either wait a day,
# or if you must remove sooner, delete the bucket after the window; empty first.
terraform destroy \
  -var "bucket_name=$BUCKET" -var "pipeline_role_arn=<arn>"
```
```

- [ ] **Step 4: Add the dormant upload step to the workflow**

After the "Bundle, hash, and sign the evidence" step in the `grc-gate` job, add:

```yaml
      - name: Upload signed bundle to the immutable vault (dormant)
        if: always() && vars.EVIDENCE_VAULT_BUCKET != ''
        run: |
          set -euo pipefail
          KEY="runs/${{ github.run_id }}/evidence.tar.gz"
          aws s3api put-object --bucket "${{ vars.EVIDENCE_VAULT_BUCKET }}" \
            --key "$KEY" --body "${WEEK3_DIR}/evidence.tar.gz"
          aws s3api put-object --bucket "${{ vars.EVIDENCE_VAULT_BUCKET }}" \
            --key "$KEY.sig.bundle" --body "${WEEK3_DIR}/evidence.tar.gz.sig.bundle"
          echo "Vaulted $KEY"
```

Note: this step is skipped (not failed) whenever `EVIDENCE_VAULT_BUCKET` is unset. It relies on the OIDC AWS credentials configured for the vault; document in the README that enabling it requires wiring `aws-actions/configure-aws-credentials` into this job (out of scope while dormant).

- [ ] **Step 5: Lint + commit**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/grc-gate.yml')); print('yaml OK')"
git add 6week-challenge/week4/vault/ .github/workflows/grc-gate.yml
git commit -m "week4: dormant S3 Object Lock evidence vault (preservation stretch)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Submission writeup

**Files:**
- Create: `6week-challenge/week4/SUBMISSION.md`

**Interfaces:**
- Consumes: all prior artifacts (verify script, workflow, tamper logs/screenshots, vault).
- Produces: the portfolio writeup mapping the four custody properties to artifacts.

- [ ] **Step 1: Write `SUBMISSION.md`**

Follow the week-3 house style (`6week-challenge/week3/SUBMISSION.md`). Required sections:
- **Writeup:** why signing removes the need to trust us; keyless vs stored key.
- **Four custody properties → artifact** table (copy from the spec, link each row).
- **The one technique:** move the pass/fail decision to the last step so a *failed* run is still signed and preserved.
- **Proof — the tamper test:** embed `GRCChallenge-week4-tamper-test.png`; show the `CHAIN INTACT` run beside the `FAIL: integrity` run; quote both captured logs.
- **Stretch:** dormant Object Lock vault — the overwrite-refused property.
- **Evidence index** table.
- **Done when** checklist including the LinkedIn item (tag GRC Engineering Club, `#GRCEngClubChallenge`, explain why keyless beats a stored key).

- [ ] **Step 2: Link-check + commit**

```bash
# verify every relative link in the writeup resolves
grep -oE '\]\(([^)]+)\)' 6week-challenge/week4/SUBMISSION.md | sed -E 's/\]\(([^)]+)\)/\1/' \
  | grep -vE '^https?:' | while read -r p; do \
      f="6week-challenge/week4/${p%%#*}"; [ -e "$f" ] || echo "MISSING: $p"; done
git add 6week-challenge/week4/SUBMISSION.md
git commit -m "week4: submission writeup — chain of custody, tamper test, vault stretch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Expected: no `MISSING:` lines.

---

## Self-Review

**Spec coverage:**
- Custody map / four properties → Task 1 (checks) + Task 5 (writeup table). ✓
- CI signing step: id-token perm, verdict decouple, sign, upload, final enforce → Task 2. ✓
- verify-evidence.sh three checks + parameterization → Task 1. ✓
- Tamper test + local session run → Task 3. ✓
- Dormant vault + Object Lock + dormant upload step → Task 4. ✓
- Submission writeup → Task 5. ✓
- Committed bundle for independent re-verification → Task 3 Step 7. ✓
- Bundle contents = gate output (conftest-results + plan.json) → Task 3 Step 2 / Task 2 Step 3. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full content. Task 5 is prose-generation (a writeup) with an explicit required-section list rather than literal final copy — acceptable, as final wording depends on the actual run output and screenshots produced in Task 3.

**Type/name consistency:** `EXPECT_ISSUER`/`EXPECT_IDENTITY`/`EVIDENCE_VAULT_BUCKET`/`EVIDENCE_VAULT_KEY` identical across Task 1, 3, 4. Bundle/sidecar/sig names consistent everywhere (`evidence.tar.gz[.sha256|.sig.bundle]`). `steps.gate.outputs.gate` set in Task 2 Step 2, read in Task 2 Step 5. ✓

**Known caveat:** The default CI `EXPECT_IDENTITY` regexp allows any ref (`@refs/.*`) so a PR-branch run verifies; tighten to `@refs/heads/main` for strict main-only verification if desired (documented in Task 1 script comment).
