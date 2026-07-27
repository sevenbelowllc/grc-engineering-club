# Week 3 evidence — provenance

## `conftest-results.json`

The machine-readable verdict from the policy gate: three namespaces
(`sc28_aws`, `ac3_aws`, `cm6_aws`), one success each, zero failures.

**Where it came from.** This file is produced by CI, not by hand. The gate writes
it at [`.github/workflows/grc-gate.yml`](../../../.github/workflows/grc-gate.yml)
(the "Run policy gate" step), then does two things with it: uploads it as a build
artifact, and seals it into the signed evidence bundle. CI deliberately does **not**
commit it back — a gate that writes into the repository it is gating is a pattern
worth avoiding.

That is why this file was absent from the repo for weeks 3–5 even though the week-3
README and SUBMISSION both refer to it: it existed in CI's workspace, in the run
artifact, and inside the signed tarball, but never in git.

**How this copy was recovered.** Extracted from the signed bundle:

```bash
tar xzOf ../../week-4/evidence/evidence.tar.gz conftest-results.json
```

It is byte-identical to the copy inside that bundle —
SHA-256 `6725fb42…a52d671` — so it inherits the bundle's chain of custody rather
than being a fresh, unattested re-run. Verify the containing bundle with:

```bash
cd ../../week-4 && ./verify-evidence.sh evidence/evidence.tar.gz
```

**Why the `filename` field says `week3/`, not `week-3/`.** The run that produced
this verdict is from 2026-07-21, before commit `3c5da8e` renamed the week
directories to the `week-<N>` scheme. The path recorded inside is the path that
existed when the gate ran.

That discrepancy is left in place on purpose. Editing the contents of signed
evidence so it matches the current tree would make the file tidier and the
attestation worthless — the signature covers these exact bytes. Evidence records
what happened, not what is convenient now.

## Screenshots

The remaining PNGs in this directory are the green/red pull-request runs and the
gate's PR comment, captured from the GitHub Actions UI at the time of each run.
