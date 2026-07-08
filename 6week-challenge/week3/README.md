# Week 3 — Build the Gate

A policy you run on your laptop catches your own mistakes. A policy you run in CI
catches everyone's, on every change, forever. This week wires the three week-2
policies into a **GitHub Actions gate** that runs on every pull request to `main`
and blocks the ones that break a control.

## What the gate enforces

On every PR to `main`, [`.github/workflows/grc-gate.yml`](../../.github/workflows/grc-gate.yml)
runs [Conftest](https://www.conftest.dev/) `v0.68.2` (pinned) against the
committed [`plan.json`](./plan.json) using the three week-2 policy namespaces:

| Namespace | Control | Denies |
| --- | --- | --- |
| `compliance.sc28_aws` | **SC-28** Encryption at Rest | any `aws_s3_bucket` with no matching server-side encryption configuration |
| `compliance.ac3_aws` | **AC-3** Access Enforcement | any `aws_s3_bucket` whose public access block is missing or has any of its four flags not `true` |
| `compliance.cm6_aws` | **CM-6** Configuration Settings | any taggable resource missing one of the four required tags |

## What happens when a control breaks

The gate is **fail-closed**. Conftest exits non-zero on any violation, and
`set -o pipefail` propagates that through the `tee` that captures the evidence —
so the job **fails while still saving the evidence**. The result is uploaded as a
build artifact with `if: always()`, and the verdict is posted as a PR comment.

With branch protection requiring the `grc-gate` check, **a PR that breaks a
control cannot be merged by anyone until it is fixed.** That sentence is the
entire value proposition: GRC stops being a meeting. Nobody reviews the change for
encryption — the pipeline does, in seconds, and a human only gets involved when
something is actually wrong.

## Layout

```
.github/workflows/grc-gate.yml   the LIVE gate (must be at repo root to trigger)
6week-challenge/week3/
  policies/           the three week-2 deny policies (tests stay in week2)
  plan.json           committed COMPLIANT plan — the green-PR fixture
  plan-broken.json    same plan with encryption removed — the red-PR fixture
  terraform/          the week-1 build; source the OIDC job regenerates from
  evidence/           where the gate writes conftest-results.json
  oidc/               stretch: keyless CI (GitHub OIDC → read-only AWS role)
  RUNBOOK.md          the two-PR demonstration, step by step
  week-3/             the original starter skeleton (reference only; its nested
                      workflow cannot trigger — the live one is at repo root)
```

> **Why the workflow is at the repo root, not in this folder.** GitHub Actions
> only discovers workflows under `.github/workflows/` at the repository root. The
> starter shipped a copy nested under `week3/week-3/.github/workflows/`, which can
> never run. It is kept for reference; the working gate is at the repo root and
> points its `--policy` and plan paths back into this folder.

## The two-PR demonstration

The deliverable is two pull requests — one green, one red — with branch
protection making the red one un-mergeable. Full steps are in
[`RUNBOOK.md`](./RUNBOOK.md). In short:

1. **Green PR** — the committed `plan.json` is compliant; every namespace passes;
   the check goes green; the PR is mergeable.
2. **Red PR** — swap in `plan-broken.json` (encryption removed); SC-28 fails; the
   check goes red; branch protection blocks the merge.

## Stretch: keyless plan generation via OIDC

The production version does not commit a plan — CI generates it by assuming a
**read-only AWS role through GitHub OIDC**, with no stored keys, bound to this
exact repo. It ships as a dormant second job (`grc-gate-oidc`) plus the IAM
terraform to enable it. See [`oidc/README-oidc.md`](./oidc/README-oidc.md).

## Reproduce the gate locally

```bash
cd 6week-challenge/week3
conftest test plan.json --policy policies \
  --namespace compliance.sc28_aws \
  --namespace compliance.ac3_aws \
  --namespace compliance.cm6_aws
# swap plan.json -> plan-broken.json to watch SC-28 fail
```
