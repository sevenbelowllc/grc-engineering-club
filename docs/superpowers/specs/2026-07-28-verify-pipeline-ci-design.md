# Design — run `verify-pipeline.sh` in CI

**Date:** 2026-07-28 · **Branch:** `ci-verify-pipeline` · **Base:** `6cf50f9`

## Problem

`verify-pipeline.sh` is the repo's single verdict on itself: twelve checks
spanning `terraform validate`, the policy gate in both directions, OSCAL schema
validity, signature verification, vault preservation, and a full profile →
evidence traversal. It has never run in CI. It runs when a person remembers to
run it.

That gap has already cost something. Three bugs shipped in the week-6 session
were found only by running the code on a machine other than the one that wrote
it, and all three had the same shape: **something reported success while
verifying nothing.** One of them had `traverse.sh` walking zero controls and
exiting green. A CI job would have caught every one on first push.

## The trap this design exists to avoid

The naive job — install the tools, run the script, use its exit code — is worse
than nothing, because of `verify-pipeline.sh:214-218`:

```bash
if [ "$SKIP" -gt 0 ]; then
  title "PIPELINE PASS (with $SKIP check(s) skipped — see above)"
  exit 0
fi
```

A skipped check exits zero. If a tool silently stops installing, its checks
become SKIP, the script exits 0, and the badge is green while the verification
it names never happened. That is the precise failure the repo already argues
against in `oscal-from-conftest.py`'s mapping guard and in the case study's
"An absent verdict is not a passing verdict".

A CI job that can go green without verifying anything would be the repo
contradicting its own thesis in its own build.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Credentials | Run **with** OIDC credentials | Nothing skips, so the full twelve run. A partial run is the thing being guarded against. |
| Retention | `vault_retention_days` 1 → **30** | Credentialed runs check that Object Lock retention is still in the future. At 1 day the job goes red daily on PRs that changed nothing. |
| Enforcement | **Required** status check | The case study argues a blocked merge beats a caught mistake. An advisory check nobody must read is the monitoring posture the repo criticises. |
| Placement | Third job in `grc-gate.yml` | Reuses the workflow-level `CONFTEST_VERSION` pin. Adds no new version-pin site; the repo already carries pins in eight places as known debt. |
| IAM | **No change** | `grc-gate-oidc` already has `ReadOnlyAccess`, which covers `s3:GetObjectRetention`. Writes come from a narrow bucket policy (`Sid: PipelinePutOnly`), so the role stays read-only for this job by construction. |

## Design

### The job

A third job in `.github/workflows/grc-gate.yml`, alongside `grc-gate` and
`grc-gate-oidc`:

```yaml
verify-pipeline:
  runs-on: ubuntu-latest
  permissions:
    contents: read
    id-token: write        # OIDC exchange for the read-only vault legs
  steps:
    - actions/checkout@v4
    - hashicorp/setup-terraform@v3       # terraform_wrapper: false
    - install conftest ${{ env.CONFTEST_VERSION }}
    - actions/setup-python + compliance-trestle
    - sigstore/cosign-installer@v4
    - aws-actions/configure-aws-credentials@v4   # grc-gate-oidc
    - run: ./verify-pipeline.sh
```

`jq` and the AWS CLI are preinstalled on `ubuntu-latest`. The conftest, python,
trestle and cosign steps mirror the existing `grc-gate` steps rather than
inventing new ones, so the two jobs install identical tooling at identical
versions.

Expected runtime 2-4 minutes, dominated by four `terraform init` provider
downloads (`verify-pipeline.sh:93` initialises `week-1/solution`,
`week-3/terraform`, `week-5/terraform` and `week-6/terraform`).

### Failure semantics

The job must not rely on the script's exit code alone. It asserts the expected
shape of the run:

- **`0 skipped` is asserted explicitly.** The step captures the transcript,
  parses the `N passed, N failed, N skipped` summary line the script already
  emits (`verify-pipeline.sh:204`), and fails the job when the skipped count is
  anything but zero. With credentials present nothing is supposed to skip, so a
  non-zero count means a tool failed to install — a job failure, not a
  footnote. Parsing the script's existing output avoids adding a `--strict`
  flag and keeps the local and CI runs the same command.
- Any check failing fails the job, via the script's own exit 1.
- The transcript is printed in full to the job log, so a red run says which
  check and why without anyone re-running it locally.

This is the same guard the converter applies to conftest, turned on the runner
itself: the job verifies that the checks it claims to run actually ran.

### Retention

`vault_retention_days` moves from 1 to 30 in
`6week-challenge/week-6/terraform/variables.tf`, applied against the existing
state. Changing the default retention on
`aws_s3_bucket_object_lock_configuration` is an in-place update; the plan is to
be reviewed before apply to confirm no resource is replaced.

The bucket default applies only to **new** uploads, so the four manual evidence
objects under `manual/2026-07-26/` are re-uploaded afterwards to inherit the
30-day lock. They are byte-identical to the local copies (verified by SHA-256
before the previous re-upload), so hashes and signatures are unaffected — only
the lock changes.

**This is irreversible.** COMPLIANCE-mode retention can be extended but never
shortened, by anyone including the account root. Once applied, the bucket
cannot be destroyed until late August 2026, which pins the AWS account until
then.

### Documentation

Raising retention falsifies committed statements. They change in the same
commit:

| File | Statement |
|---|---|
| `week-6/terraform/variables.tf` | "1 day is a cost/demo value" |
| `week-6/README.md` | "24 hours at the default" |
| `week-6/ASSURANCE-BOUNDARY.md` | §4 heading "One day of Object Lock is a cost demo" |
| `week-6/PORTFOLIO-CASE-STUDY.md` | "one day of Object Lock is a cost demo" |
| `www-sevenbelow` MDX | the same sentence, unpublished |

The argument in each survives unchanged: 30 days is still not the years that
real records-retention regulation requires, so the honesty point stands and
only the number moves. `ASSURANCE-BOUNDARY.md` §4 keeps its place on the list
of things the pipeline does not prove.

### Required check

`verify-pipeline` is added to the `grc-gate-required` ruleset's
`required_status_checks`, joining `grc-gate`.

## Sequencing

Ordered by dependency; each step is verified before the next begins.

1. `vault_retention_days` → 30, plan reviewed, applied
2. Re-upload the four manual objects; confirm the new `RetainUntilDate`
3. Update the five documentation sites
4. Add the `verify-pipeline` job
5. Open a PR; confirm the job goes green **and** reports `0 skipped`
6. Add `verify-pipeline` to the required-checks ruleset

The ruleset change is last on purpose. Adding a required check that has never
passed would wedge every merge in the repository behind a job whose first run
has not happened yet.

## Out of scope

- A composite action to de-duplicate the toolchain across jobs. It is the right
  long-term fix for the eight-places-pinned debt, but it rewrites the install
  steps of a currently-green required gate, and that is a larger blast radius
  than this change needs.
- A scheduled run on `main`. Worth having, but the PR path is where a blocked
  merge has value; a schedule can be added later without touching this design.
- Unit tests for `oscal-from-conftest.py`, still proven by a committed
  transcript rather than a test. Unrelated to this change.

## Risks

| Risk | Mitigation |
|---|---|
| First run fails and blocks merges | Ruleset change is sequenced last, after a green run |
| An AWS-side failure reddens unrelated PRs | Accepted. The job is read-only and the role is scoped to this repository; the alternative is a check that does not verify preservation at all. |
| 30-day lock pins the account | Accepted deliberately, recorded here and in the docs |
| Job runtime slows the PR loop | 2-4 min against grc-gate's 30s. Accepted; it runs in parallel with the other jobs. |
