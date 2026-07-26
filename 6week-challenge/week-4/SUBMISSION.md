# Week 4 Submission — Evidence You Can Trust

## Writeup

Week 3 built a gate that produces evidence on every run. But that evidence was
only as trustworthy as our word: an auditor had to *take on faith* that the
`conftest-results.json` and `plan.json` in the artifact were the real ones and
that nobody edited them. Week 4 removes the faith. We **sign the evidence** so
anyone can prove it is authentic and untouched — without trusting us at all.

Chain of custody, stripped of jargon, is four questions about a piece of
evidence. Each is now answered by a specific artifact:

| Property | Question | Answered by | Artifact |
| --- | --- | --- | --- |
| **Integrity** | Has it changed since? | SHA-256 of the bundle | [`evidence.tar.gz.sha256`](evidence/evidence.tar.gz.sha256) |
| **Authenticity** | Who produced this? | Keyless signature bound to repo + workflow | [`evidence.tar.gz.sig.bundle`](evidence/evidence.tar.gz.sig.bundle) |
| **Timeliness** | When was it produced? | Signed timestamp + transparency-log inclusion | same [`.sig.bundle`](evidence/evidence.tar.gz.sig.bundle) |
| **Preservation** *(stretch, dormant)* | Can it still be retrieved, unaltered? | S3 Object Lock retention in the future | [`vault/vault.tf`](vault/vault.tf) |

Week 3 already gave us integrity halfway, from the hashes. Week 4 adds
authenticity and timeliness through signing; preservation is the dormant stretch.

## Keyless signing, and why it beats a stored key

The old way to sign was to generate a private key, guard it forever, and hope it
never leaks. Cosign does **keyless** signing instead. In GitHub Actions the
pipeline proves its identity with a short-lived OIDC token, Sigstore's CA
(Fulcio) issues a momentary certificate bound to that identity, signs, and
records the event in a public transparency log (Rekor). There is no long-lived
key to store, rotate, or lose.

The certificate literally encodes *which repository and which workflow* produced
the signature. Our authoritative bundle's certificate carries the identity:

```
URI:https://github.com/sevenbelowllc/grc-engineering-club/.github/workflows/grc-gate.yml@refs/pull/9/merge
issuer: https://token.actions.githubusercontent.com
```

That fact does not live in our cloud account — it lives in Sigstore. Which is
exactly why it is trustworthy: even someone with admin in our AWS account cannot
forge it, because the proof is not in our infrastructure. A stored key can be
stolen; this identity cannot be, because there is nothing to steal.

## The one technique: sign the failures too

The natural mistake is to let the policy gate fail the job the moment a control
breaks — which would abort the run *before* the signing step. But a failed run
is exactly the evidence you most want preserved and provable. So the gate step no
longer decides pass/fail; it only **records** the verdict:

```bash
set -o pipefail
if conftest test … --output json | tee evidence/conftest-results.json; then
  echo "gate=pass" >> "$GITHUB_OUTPUT"
else
  echo "gate=fail" >> "$GITHUB_OUTPUT"
fi
```

Wrapping the pipeline in `if …; then … else … fi` suppresses `set -e` on a
violation (so the step doesn't abort), while `set -o pipefail` still carries
Conftest's exit code into the condition. Signing runs next, unconditionally. The
**last** step in the job is the single source of the red/green decision:

```bash
[ "$GATE" = "pass" ] || { echo "a control failed"; exit 1; }
```

Net effect: whether the gate passes or fails, the evidence is bundled, signed,
and uploaded first — *then* the job goes red if a control broke. The signing step
lives in the committed workflow at
[`.github/workflows/grc-gate.yml`](../../.github/workflows/grc-gate.yml);
`id-token: write` is granted at the job level so Cosign can mint its OIDC token.

## Proof: the tamper test

This is the deliverable. The authoritative bundle was signed by
[PR #9](https://github.com/sevenbelowllc/grc-engineering-club/pull/9), CI run
`29882651018` — all three controls passed
(`sc28_aws`, `ac3_aws`, `cm6_aws`, each `"successes": 1` with no `failures`
entries). The signed
bundle contains exactly that run's `conftest-results.json` and the `plan.json` it
evaluated.

Running the verifier against the real bundle — [`ci-verify-pass.txt`](evidence/ci-verify-pass.txt):

```
$ ./verify-evidence.sh evidence/evidence.tar.gz
integrity:    OK  (3dd2a1afc03e35fe73d46c12823e41871abd1f5fccea1b0d4239994b83c9448e)
authenticity: OK  (issuer=https://token.actions.githubusercontent.com)
preservation: skipped (no vault configured)
CHAIN INTACT
```

Now copy the bundle, append a **single line** of junk, and verify again —
[`ci-verify-tamper-fail.txt`](evidence/ci-verify-tamper-fail.txt):

```
# original sha256: 3dd2a1afc03e35fe73d46c12823e41871abd1f5fccea1b0d4239994b83c9448e
# tampered sha256: 60f63264328624fc52a663f28e165377a32008764df0c85e7805283010ac4d80
$ ./verify-evidence.sh /tmp/w4tamper.tar.gz
FAIL: integrity: sha256 mismatch (bundle was modified)
exit=1
```

One changed byte breaks the chain — it fails immediately on integrity, before the
signature is even checked, because the hash no longer matches and the signature
was computed over the original bytes. These logs are committed, so anyone who
clones the repo and installs Cosign can reproduce both runs and confirm them
independently. That reproducibility is the point: custody here is mathematical,
not a promise.

> For the LinkedIn post, screenshot the two runs side by side — the passing
> `CHAIN INTACT` next to the `FAIL: integrity` — and save under `evidence/` as
> `GRCChallenge-week4-tamper-test.png`.

## The verify script

[`verify-evidence.sh`](verify-evidence.sh) runs three checks, each exiting
non-zero on failure, and prints `CHAIN INTACT` only when all executed checks pass:

1. **Integrity** — recompute the bundle's SHA-256 (OS-detecting `sha256sum` /
   `shasum -a 256`) and compare to the sidecar.
2. **Authenticity + timeliness** — `cosign verify-blob` against the `.sig.bundle`,
   pinning the OIDC issuer to GitHub Actions and the certificate identity to this
   repo's `grc-gate.yml` (both overridable via `EXPECT_ISSUER` / `EXPECT_IDENTITY`
   for a locally-signed bundle).
3. **Preservation** — dormant; runs only when `EVIDENCE_VAULT_BUCKET` /
   `EVIDENCE_VAULT_KEY` are set, asserting the Object Lock retention is still in
   the future.

## Stretch: the immutable vault (dormant)

True preservation means the signed bundle cannot be overwritten or deleted, even
by us, before its retention expires. [`vault/vault.tf`](vault/vault.tf) defines an
S3 bucket with **versioning** and **Object Lock (COMPLIANCE mode)** enabled at
creation, a tightly scoped IAM policy granting the pipeline role only
`s3:PutObject` on that bucket, and a full public-access block. A workflow step
uploads the signed bundle to it — gated on the `EVIDENCE_VAULT_BUCKET` repo
variable, so it stays **skipped** until you opt in, mirroring week 3's dormant
OIDC job. The interesting property to test is that overwriting an existing object
is *refused* by Object Lock: a tampered bundle has nowhere to live except a
laptop. See [`vault/README.md`](vault/README.md) for apply → verify → teardown
(pennies, torn down the same day).

## Evidence index

| Artifact | What it proves |
| --- | --- |
| [`.github/workflows/grc-gate.yml`](../../.github/workflows/grc-gate.yml) | The committed signing step — sign-then-enforce, keyless, `id-token: write` |
| [`verify-evidence.sh`](verify-evidence.sh) | The verifier — integrity, authenticity/timeliness, preservation |
| [`evidence/evidence.tar.gz`](evidence/evidence.tar.gz) | The signed bundle — this run's `conftest-results.json` + `plan.json` |
| [`evidence/evidence.tar.gz.sha256`](evidence/evidence.tar.gz.sha256) | Integrity — the hash the tamper test breaks |
| [`evidence/evidence.tar.gz.sig.bundle`](evidence/evidence.tar.gz.sig.bundle) | Authenticity + timeliness — cert (repo+workflow identity), signature, Rekor entry |
| [`evidence/ci-verify-pass.txt`](evidence/ci-verify-pass.txt) | `CHAIN INTACT` against the authoritative CI bundle |
| [`evidence/ci-verify-tamper-fail.txt`](evidence/ci-verify-tamper-fail.txt) | One appended byte → `FAIL: integrity`, exit 1 |
| [PR #9](https://github.com/sevenbelowllc/grc-engineering-club/pull/9) (run `29882651018`) | The authoritative signing event — identity bound to `grc-gate.yml` |
| [`vault/`](vault/) | Dormant S3 Object Lock vault — the preservation stretch |

## Done when — checklist

- [x] A signing step in the committed workflow signs the gate's evidence, keyless
- [x] Signing runs even when the gate fails a control (sign-then-enforce)
- [x] `verify-evidence.sh` implements integrity, authenticity, and (dormant) preservation
- [x] The authoritative bundle verifies `CHAIN INTACT` with the default GitHub Actions pins
- [x] The tamper test fails on integrity from a single appended byte (exit 1), captured and committed
- [x] A writeup maps each of the four custody properties to the artifact that proves it
- [x] Stretch: dormant S3 Object Lock vault shipped (Terraform + runbook + gated upload step)
- [x] Post to LinkedIn (pass beside fail), tagging GRC Engineering Club with `#GRCEngClubChallenge`, explaining why keyless signing beats a stored key
