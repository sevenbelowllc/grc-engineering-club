# Week 3 runbook — the two-PR demonstration

This is the part a human runs. The files (the gate, the policies, the fixtures)
are already committed. What's left is proving the gate works by opening one PR
that passes and one that is blocked, with branch protection making the block real.

> The green PR is the one that adds this gate. Because `pull_request` workflows
> run using the workflow file **from the PR branch**, the gate runs on the very
> PR that introduces it — no need to merge it to `main` first.

## 0. Prerequisites (once)

- The branch adding `.github/workflows/grc-gate.yml` and `6week-challenge/week3/`
  is pushed and its PR to `main` is open. (If Claude created it, this is done.)

## 1. Green PR — the gate passes

1. Open the PR that adds the gate (`week3-challenge` → `main`).
2. Watch **Actions** → the `grc-gate` workflow runs on the PR.
3. Every namespace passes → the `grc-gate` check goes **green**, and the bot
   comments `grc-gate: ✅ pass`.
4. Confirm the **grc-gate-evidence** artifact is attached to the run.
5. **Screenshot** the green check.

## 2. Turn on branch protection (before the red PR)

Settings → Branches → Add branch protection rule for `main`:

- **Require status checks to pass before merging** → add **`grc-gate`**.
- (Recommended) Require a PR before merging.

> Do not add a `paths:` filter to the workflow. A required check that gets
> skipped on an unrelated PR blocks the merge — so the gate is left running on
> every PR to `main`, which is what makes it reliably reportable as required.

## 3. Red PR — the gate blocks the merge

1. New branch off `main`:
   ```bash
   git switch -c week3-red-demo main
   cp 6week-challenge/week3/plan-broken.json 6week-challenge/week3/plan.json
   git commit -am "week3: red demo — remove encryption, break SC-28"
   git push -u origin week3-red-demo
   gh pr create --base main --title "week3 RED: break SC-28 (encryption removed)" \
     --body "Intentional control break to demonstrate the gate fails closed and the merge is blocked."
   ```
2. The gate runs, SC-28 reports two failures (both buckets), the `grc-gate` check
   goes **red**, and the bot comments `grc-gate: ❌ fail` naming the offending
   resources.
3. The **Merge** button is disabled — the required check is failing. The red PR
   **cannot be merged by anyone** until `plan.json` is compliant again.
4. Confirm the **grc-gate-evidence** artifact is attached to the failing run too
   (that's the `if: always()` upload — evidence survives the failure).
5. **Screenshot** the red check and the blocked merge button.

## 4. Clean up

- Close the red PR (or fix it) and delete `week3-red-demo`.
- Merge the green PR. The workflow file stays — it is the deliverable.

## 5. Portfolio

- `.github/workflows/grc-gate.yml` in the public repo.
- Links to both PRs (green and red) in the repo history.
- The README section explaining what the gate enforces and what breaking a
  control does.
- LinkedIn: post both checks side by side, green and red. Tag **GRC Engineering
  Club**, use **#GRCEngClubChallenge**, and explain why a blocked merge beats a
  caught mistake.

---

## Stretch (optional) — enable the keyless OIDC job

Only after you want CI to generate the plan itself. See
[`oidc/README-oidc.md`](./oidc/README-oidc.md):

```bash
cd 6week-challenge/week3/oidc && terraform init && terraform apply
gh variable set AWS_GATE_ROLE_ARN --body "$(terraform output -raw role_arn)"
```

The `grc-gate-oidc` job stays skipped until `AWS_GATE_ROLE_ARN` is set, so this
never blocks the main deliverable.
