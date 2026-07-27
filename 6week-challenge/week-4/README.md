# Week 4 — Evidence You Can Trust

Chain of custody means anyone can prove the evidence is authentic and untouched
**without trusting the person who produced it**. Three weeks of gate output was
worth exactly as much as your willingness to believe me. This week fixes that.

**Status:** complete. The signing step runs in CI, the verifier checks four legs,
and the tamper test fails on one appended byte.

```bash
./verify-evidence.sh evidence/evidence.tar.gz
# integrity:    OK  (3dd2a1af…)
# authenticity: OK  (issuer=https://token.actions.githubusercontent.com)
# preservation: OK  (locked until 2026-07-28T02:09:29Z)
# CHAIN INTACT
```

Full writeup: **[SUBMISSION.md](SUBMISSION.md)**.

## Four legs, four separate mechanisms

The thing that took a while to see is that "trustworthy evidence" is not one
property. It is four, and each needs its own mechanism — which is why a programme
that has done only one of them usually believes it has done all four.

| Leg | Mechanism | Proves | Says nothing about |
|---|---|---|---|
| **Integrity** | SHA-256 sidecar | The bytes did not change | Who produced them |
| **Authenticity** | cosign keyless signature | Which identity signed | When |
| **Timeliness** | Rekor transparency log | The signature existed at a point in time | Whether it can be deleted |
| **Preservation** | S3 Object Lock, COMPLIANCE mode | It cannot be deleted by anyone, including root | Whether the content is true |

[`verify-evidence.sh`](verify-evidence.sh) checks all four and prints
`CHAIN INTACT` only when every executed check passes. Without vault credentials
the preservation leg reports `skipped` rather than passing — an unreadable vault
is not a verified vault.

## What is here

| | |
|---|---|
| [`verify-evidence.sh`](verify-evidence.sh) | The verifier. Used by every later week and by [`traverse.sh`](../../traverse.sh) |
| [`evidence/evidence.tar.gz`](evidence/) | The CI-signed bundle: the Terraform plan and the conftest verdicts from [PR #9](https://github.com/sevenbelowllc/grc-engineering-club/pull/9) |
| [`evidence/ci-verify-pass.txt`](evidence/ci-verify-pass.txt) | The verifier against the real bundle → `CHAIN INTACT` |
| [`evidence/ci-verify-tamper-fail.txt`](evidence/ci-verify-tamper-fail.txt) | The verifier against the same bundle with one line appended → `FAIL` |
| [`vault/`](vault/) | The original Object Lock vault design |
| [`worm-vs-iam-preservation-deep-dive.md`](worm-vs-iam-preservation-deep-dive.md) | Why a deny-delete IAM policy is not WORM |

## Keyless signing, and why it beats a stored key

```bash
cosign sign-blob --yes --bundle evidence.tar.gz.sig.bundle evidence.tar.gz
```

No private key exists. In GitHub Actions, cosign exchanges the workflow's OIDC
token for a short-lived certificate from Fulcio, signs, and records the entry in
the Rekor transparency log. The certificate's identity is the *workflow*:

```
https://github.com/sevenbelowllc/grc-engineering-club/.github/workflows/grc-gate.yml@refs/pull/9/merge
```

A stored key proves somebody had the key. This proves a specific workflow, at a
specific ref, in a specific repository, produced this artifact — and there is no
key material to leak, rotate, or find sitting in a bucket two years from now. The
job needs `permissions: id-token: write` or signing fails silently in a way that
takes an hour to diagnose.

`verify-evidence.sh` pins both the issuer and the certificate identity, because
an unpinned `cosign verify-blob` will happily accept a signature from anyone at
all. That is verification in form only.

## The technique worth stealing: sign the failures too

The signing step in [`grc-gate.yml`](../../.github/workflows/grc-gate.yml) runs
under `if: always()`, so a run where a control **failed** still bundles, signs,
and vaults its evidence.

Most pipelines discard evidence on failure, which quietly turns the archive into
a record of successes. An auditor asking *"show me a control failure and what
happened next"* then gets an answer assembled from memory. Here the red run's
bundle carries the same workflow signature as the green one, and the failure is
as provable as the pass.

## The tamper test

```bash
cp evidence/evidence.tar.gz /tmp/tampered.tar.gz
echo "junk" >> /tmp/tampered.tar.gz
./verify-evidence.sh /tmp/tampered.tar.gz     # FAIL: sha256 mismatch, exit 1
./verify-evidence.sh evidence/evidence.tar.gz # CHAIN INTACT
```

One appended byte breaks the chain. Custody is arithmetic, not a promise.
Transcript: [`evidence/ci-verify-tamper-fail.txt`](evidence/ci-verify-tamper-fail.txt).

## The vault is no longer a stretch goal

Week 4 shipped the vault as dormant — a Terraform module, and a preservation
check in the verifier that stayed `skipped` because nothing had been applied.

It is live now. The capstone composes this design with week 3's OIDC role into
[`week-6/terraform/`](../week-6/terraform/), because an S3 bucket policy cannot
name a principal that does not exist yet, so the two had to be applied together.
Both the week-4 and week-5 bundles are deposited under COMPLIANCE-mode Object
Lock, and a hard delete attempted with **admin** credentials was refused:

> `An error occurred (AccessDenied) when calling the DeleteObject operation:`
> `Access Denied because object protected by object lock.`

[Proof.](../week-6/evidence/vault-preservation-proof.txt) That is what turns the
verifier's third check from `skipped` into `OK`.

Read [`worm-vs-iam-preservation-deep-dive.md`](worm-vs-iam-preservation-deep-dive.md)
for why COMPLIANCE mode rather than GOVERNANCE, and why a deny-delete IAM policy
is not a substitute for either.

## Cost

Free. Sigstore signing and verification cost nothing and need no cloud account.
The vault is pennies — the real constraint is that COMPLIANCE-mode Object Lock
means `terraform destroy` fails until the last uploaded object's retention
expires.
