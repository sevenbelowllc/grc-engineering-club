# Week 4 Design — Evidence You Can Trust (Chain of Custody)

**Date:** 2026-07-20
**Repo:** `sevenbelowllc/grc-engineering-club`
**Status:** Approved for planning

## Problem

The week 3 gate produces evidence (`conftest-results.json`, the `plan.json` it
evaluated) on every run, but that evidence is only as trustworthy as our word.
An auditor has to take on faith that the artifact was not edited. Week 4 removes
the faith: we **sign the evidence** so anyone can verify it is authentic and
untouched without trusting us, and we build a **verify script** plus a **tamper
test** that proves the chain is mathematical, not a promise.

## Chain of custody — four properties, four artifacts

| Property | Question it answers | How we answer it | Artifact |
|---|---|---|---|
| **Integrity** | Has it changed since? | SHA-256 of the bundle | `evidence.tar.gz.sha256` sidecar |
| **Authenticity** | Who produced this? | Keyless signature bound to repo + workflow identity | `evidence.tar.gz.sig.bundle` (cert + signature + Rekor entry) |
| **Timeliness** | When was it produced? | Signed timestamp + transparency-log inclusion | same `.sig.bundle`, validated by `cosign verify-blob` |
| **Preservation** *(dormant stretch)* | Can it still be retrieved, unaltered? | S3 Object Lock retention still in the future | `aws s3api get-object-retention` check |

Integrity is already half-solved by week 3's hashing habit. Week 4 adds
authenticity and timeliness through keyless signing; preservation is the dormant
stretch.

## Decisions (locked)

- **Signing location:** CI is authoritative — the signature must be bound to the
  `repo + workflow` identity, which only a GitHub Actions run can prove. Local
  signing is a documented learn-the-flow path used to generate tamper-test
  evidence this session.
- **Session scope:** implement the code (workflow signing step + `verify-evidence.sh`)
  and exercise it locally to produce tamper-test evidence now. The
  portfolio-grade signature comes from a later CI run the user triggers.
- **Vault stretch:** ship it **dormant** — Terraform + verify logic present but
  inactive by default, mirroring week 3's dormant `AWS_GATE_ROLE_ARN` OIDC job.
  No AWS spend this session.
- **Bundle contents:** the gate output from the run (`conftest-results.json` +
  the `plan.json` it evaluated). Freshest, most defensible evidence.
- **Committed artifacts:** the CI-produced `evidence.tar.gz`, `.sha256`, and
  `.sig.bundle` are committed to `6week-challenge/week4/evidence/` so anyone
  cloning the repo can independently re-verify the chain.

## Component 1 — CI signing step

Edit the **live** root workflow `.github/workflows/grc-gate.yml` (the nested
`6week-challenge/week3/week-3/.github/workflows/grc-gate.yml` copy never triggers
and is left untouched). Changes are confined to the `grc-gate` job.

**1a. Permissions.** Add a **job-level** permissions block to `grc-gate`:
`contents: read`, `pull-requests: write`, **`id-token: write`**. Scoping it to
the job (not the workflow) keeps OIDC token minting confined to where it is
needed. Without `id-token: write`, `cosign sign-blob` cannot mint its OIDC token
and signing fails — this is the most common snag.

**1b. Decouple gate execution from the verdict.** Today the "Run policy gate"
step both `tee`s evidence and fails the job via `set -o pipefail`. That would
abort the job before signing runs — but a failed run is exactly the evidence we
most want signed and preserved. So the gate step records pass/fail to a step
output instead of failing:

```bash
set -o pipefail
mkdir -p "${WEEK3_DIR}/evidence"
if conftest test "${WEEK3_DIR}/plan.json" \
     --policy "${WEEK3_DIR}/policies" \
     --namespace compliance.sc28_aws \
     --namespace compliance.ac3_aws \
     --namespace compliance.cm6_aws \
     --output json | tee "${WEEK3_DIR}/evidence/conftest-results.json"; then
  echo "gate=pass" >> "$GITHUB_OUTPUT"
else
  echo "gate=fail" >> "$GITHUB_OUTPUT"
fi
```

Using `if …; then … else … fi` means `set -e` (the default `bash -e` shell) does
**not** abort on the non-zero conftest exit — the verdict is captured, not acted
on yet.

**1c. Sign (new steps, in order).**
1. `sigstore/cosign-installer@v3` — install cosign (pinned major).
2. Bundle: `tar -czf "${WEEK3_DIR}/evidence.tar.gz" -C "${WEEK3_DIR}" evidence`.
3. Sidecar: `sha256sum "${WEEK3_DIR}/evidence.tar.gz" > "${WEEK3_DIR}/evidence.tar.gz.sha256"`.
4. Sign: `cosign sign-blob --yes --bundle "${WEEK3_DIR}/evidence.tar.gz.sig.bundle" "${WEEK3_DIR}/evidence.tar.gz"`.

The bundle's hash is computed over the exact bytes produced; the verifier
recomputes the hash of those same bytes, so tar mtime non-determinism is
irrelevant.

**1d. Upload.** Extend the existing `if: always()` upload (or add a second
artifact) to include `evidence.tar.gz`, `.sha256`, and `.sig.bundle`.

**1e. Final step enforces the verdict.** The last step in the job fails closed:

```bash
[ "${{ steps.gate.outputs.gate }}" = "pass" ] || { echo "gate failed a control"; exit 1; }
```

Net effect: a policy failure is signed and preserved **before** the job goes red.
The existing "Comment gate verdict on PR" step (already `if: always()`) is
unchanged.

## Component 2 — `verify-evidence.sh`

Fill in `6week-challenge/week4/verify-evidence.sh`. Usage:
`verify-evidence.sh <bundle.tar.gz>`. Derives `<bundle>.sha256` and
`<bundle>.sig.bundle` by naming convention. Each check exits non-zero on failure;
`CHAIN INTACT` prints only when every executed check passes.

- **Check 1 — Integrity.** OS-detect the hasher (`sha256sum` on Linux,
  `shasum -a 256` on macOS), recompute the bundle's SHA-256, compare to the
  sidecar. Mismatch → non-zero. *This is the check the tamper test trips.*
- **Check 2 — Authenticity + Timeliness.** `cosign verify-blob --bundle <sig.bundle>`
  pinning issuer and identity. Defaults target GitHub Actions:
  - `EXPECT_ISSUER` default `https://token.actions.githubusercontent.com`
  - `EXPECT_IDENTITY` default a regexp for this repo's `grc-gate.yml`
    (`--certificate-identity-regexp`).
  Both overridable via env so the **same script** verifies a local signature
  this session (`EXPECT_ISSUER` = the Sigstore OAuth issuer,
  `EXPECT_IDENTITY` = `truevail@sevenbelow.com`).
- **Check 3 — Preservation (dormant).** Runs only when `EVIDENCE_VAULT_BUCKET`
  and `EVIDENCE_VAULT_KEY` are set: `aws s3api get-object-retention` and assert
  `RetainUntilDate` is in the future. Unset → prints `preservation: skipped
  (no vault configured)` and does not fail. Keeps the script free by default.

## Component 3 — Tamper test (the deliverable) + local session run

Local tooling present: `jq`, `shasum`, `aws`, `tar`. **Missing: cosign** →
prereq `brew install cosign`.

Session steps:
1. `brew install cosign`.
2. Stage a fresh evidence bundle from current gate output (a scratch
   `evidence/` dir with `conftest-results.json` + the `plan.json`), `tar` it,
   write the `.sha256` sidecar.
3. **User** runs one interactive `cosign sign-blob --yes --bundle … evidence.tar.gz`
   (browser OAuth → `truevail@sevenbelow.com`), supplied as a `! …` command.
4. Run `verify-evidence.sh` with local issuer/identity overrides → `CHAIN INTACT`.
5. Tamper: `cp` the bundle, `echo junk >>` it, re-run `verify-evidence.sh` →
   **fails on integrity** (hash mismatch; the signature was computed over the
   original bytes). This half needs no signing and is fully deterministic.
6. Save terminal logs of both runs to `6week-challenge/week4/evidence/`; user
   screenshots the failing run beside the passing one.

The authoritative signature: after the code lands, the user opens a PR or
`workflow_dispatch`, CI signs with the repo+workflow identity, the user
downloads the artifact and runs `verify-evidence.sh` with default GitHub Actions
pins → `CHAIN INTACT`, then commits that bundle + screenshots.

## Component 4 — Dormant immutable vault (stretch)

- `6week-challenge/week4/vault/vault.tf`: an S3 bucket with **versioning** and
  **Object Lock** enabled, a compliance/governance **retention** configuration,
  and a **tightly scoped** IAM write policy for the pipeline role (put-object to
  this bucket only).
- `6week-challenge/week4/vault/README.md`: apply → push one bundle → verify
  retention → tear down the same day (pennies). Includes the overwrite test:
  attempt to overwrite an existing object and watch Object Lock refuse.
- Workflow: an **optional upload step gated on an `EVIDENCE_VAULT_BUCKET` repo
  variable** — skipped (not failing) until the variable is set, mirroring week
  3's dormant `AWS_GATE_ROLE_ARN` job. `verify-evidence.sh` Check 3 covers the
  retention assertion.

## Component 5 — Submission writeup

`6week-challenge/week4/SUBMISSION.md` in the week 3 house style:
- The four-property custody map, each row linked to its proving artifact.
- The tamper-test screenshots — failing verification beside a passing one.
- Evidence index table.
- "Done when" checklist, including the LinkedIn post item (tag GRC Engineering
  Club, `#GRCEngClubChallenge`, explain why keyless signing beats a stored key).

## Files touched

| Path | Change |
|---|---|
| `.github/workflows/grc-gate.yml` | Add id-token perm, decouple verdict, sign steps, final enforce, extend upload, dormant vault upload |
| `6week-challenge/week4/verify-evidence.sh` | Implement the three checks |
| `6week-challenge/week4/evidence/` | Committed bundle + sidecar + sig.bundle + tamper-test logs |
| `6week-challenge/week4/vault/vault.tf` | New — dormant Object Lock vault |
| `6week-challenge/week4/vault/README.md` | New — apply/verify/teardown |
| `6week-challenge/week4/SUBMISSION.md` | New — writeup |

## Out of scope

- Modifying the nested reference workflow copy under `week3/week-3/`.
- Applying the vault against real AWS this session (dormant only).
- Long-lived signing keys of any kind (keyless only — there is no key to store).

## Risks / snags

- **Missing `id-token: write`** → signing fails to mint OIDC token. Mitigated by
  job-level permission block (1a).
- **verify-blob certificate-identity mismatch** → pin issuer, and identity via
  regexp; document the local vs CI issuer/identity values.
- **Transparency-log lag** (~1s) can race a verify done microseconds after a
  local sign. Mitigated by verifying a beat after signing; CI naturally waits.
- **Verdict decoupling regression** — the gate must still fail closed. The final
  enforce step (1e) is the single source of the red/green decision; covered in
  the plan's verification.
