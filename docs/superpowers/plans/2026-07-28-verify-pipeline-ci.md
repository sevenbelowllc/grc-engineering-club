# verify-pipeline CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run `verify-pipeline.sh` on every pull request as a required status check, credentialed so all twelve checks execute and none skip.

**Architecture:** A third job in the existing `.github/workflows/grc-gate.yml`, reusing that workflow's version pins and mirroring its install steps. It assumes the existing read-only `grc-gate-oidc` role so the two vault checks run rather than skip, then asserts the run reported `0 skipped` by parsing the script's own summary line — the exit code alone is not trusted, because a skipped check exits zero.

**Tech Stack:** GitHub Actions, Terraform 1.x, conftest 0.68.2, compliance-trestle 4.2.0, cosign (sigstore/cosign-installer@v4), AWS CLI v2, jq, bash.

**Spec:** `docs/superpowers/specs/2026-07-28-verify-pipeline-ci-design.md`

## Global Constraints

- Branch: `ci-verify-pipeline`, based on `main` at `6cf50f9`.
- Tool versions are pinned and must match the existing workflow exactly: conftest `${{ env.CONFTEST_VERSION }}` (0.68.2), `compliance-trestle==4.2.0`, python `3.11`. Never `latest` — "a moving version is not evidence you can reproduce."
- Do **not** add a new version-pin site. The new job reuses the workflow-level `env: CONFTEST_VERSION`.
- Do **not** modify the shared shell helpers (`fail`, `sha256_file`, `write_sha256_sidecar`, `read_sha256_sidecar`, or the `c_bold`/`c_green`/`c_red`/`c_grey`/`rule`/`title`/`section`/`ok`/`bad`/`skip`/`need` reporting vocabulary). They are byte-identical across scripts on purpose. Change one, change all.
- Do **not** modify `verify-pipeline.sh` itself. The CI job runs the same command a human runs; strictness lives in the job, not a new `--strict` flag.
- Do **not** run `rebuild-oscal.sh`. It mints fresh UUIDs and invalidates the OSCAL signature committed in `7900c65`.
- Scripts must stay correct on bash 3.2 (macOS) and 5.2 (Linux), and on jq 1.6 and 1.7. Write `.foo[] | .["key"]`, never `.foo[].["key"]`.
- The AWS account is `232929535631`; vault bucket `grc-challenge-evidence-vault-f11fcaca` in `us-east-1`; role `arn:aws:iam::232929535631:role/grc-gate-oidc`.
- No IAM changes. The role already has `ReadOnlyAccess` (covers `s3:GetObjectRetention`); writes come from the bucket policy `Sid: PipelinePutOnly`.

---

### Task 1: Raise Object Lock retention to 30 days

**Files:**
- Modify: `6week-challenge/week-6/terraform/variables.tf:31-41`
- Verify: `verify-pipeline.sh` (run, not edited)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a vault whose four `manual/2026-07-26/` objects carry a COMPLIANCE `RetainUntilDate` roughly 30 days out. Task 3's CI job depends on that date being in the future, because `traverse.sh`'s `preservation:` leg fails when retention has lapsed.

**⚠️ This task is irreversible.** COMPLIANCE-mode retention can be extended but never shortened, by anyone including the account root. After this task the bucket cannot be destroyed until roughly 2026-08-28, which pins the AWS account until then. Confirm with the user before Step 4.

- [ ] **Step 1: Change the default and its comment**

In `6week-challenge/week-6/terraform/variables.tf`, replace the comment block and default. Current text:

```hcl
# 1 day is a cost/demo value, NOT a compliant retention period — real SEC 17a-4
# retention is measured in years. Object Lock is the *control*; meeting a
# regulation additionally requires an appropriate period, a designated third
# party, and the surrounding audit process. See
# ../../week-4/worm-vs-iam-preservation-deep-dive.md.
variable "vault_retention_days" {
  type        = number
  description = "Object Lock COMPLIANCE retention in days. Objects are undeletable for this long."
  default     = 1
```

Replace with:

```hcl
# 30 days is a demo value, NOT a compliant retention period — real SEC 17a-4
# retention is measured in years. Object Lock is the *control*; meeting a
# regulation additionally requires an appropriate period, a designated third
# party, and the surrounding audit process. See
# ../../week-4/worm-vs-iam-preservation-deep-dive.md.
#
# It was 1 day until the CI verifier arrived. verify-pipeline.sh checks that the
# vault's retention is still in the future, and at one day that check went red
# every day on pull requests that had changed nothing. 30 days is long enough
# that the check means something between runs and short enough to stay a demo.
variable "vault_retention_days" {
  type        = number
  description = "Object Lock COMPLIANCE retention in days. Objects are undeletable for this long."
  default     = 30
```

- [ ] **Step 2: Generate the plan and confirm it is an in-place update**

Run:
```bash
cd 6week-challenge/week-6/terraform && terraform init -input=false && terraform plan -no-color
```

Expected: exactly one resource change, `aws_s3_bucket_object_lock_configuration` showing `~ update in-place` with `days: 1 -> 30`.

**STOP if the plan shows any `-/+` (destroy and recreate) or touches the bucket itself.** Recreating the bucket would destroy the evidence vault. Report the plan and wait for instruction.

- [ ] **Step 3: Confirm with the user before applying**

Show the plan output and state plainly: this apply is irreversible and pins the account until roughly 2026-08-28. Wait for explicit approval.

- [ ] **Step 4: Apply**

Run:
```bash
cd 6week-challenge/week-6/terraform && terraform apply -auto-approve -no-color
```

Expected: `Apply complete! Resources: 0 added, 1 changed, 0 destroyed.`

- [ ] **Step 5: Verify the bucket default actually changed**

Run:
```bash
aws s3api get-object-lock-configuration --bucket grc-challenge-evidence-vault-f11fcaca
```

Expected: `"Mode": "COMPLIANCE"`, `"Days": 30`.

- [ ] **Step 6: Re-upload the four manual objects so they inherit the new default**

The bucket default applies only to new uploads; the existing objects keep their old lock. The local copies are byte-identical to the vault copies (verified by SHA-256 earlier this session), so only the lock changes.

```bash
cd /Users/pollucts/workdir/grc-engineering-club
B=grc-challenge-evidence-vault-f11fcaca
for pair in "6week-challenge/week-4/evidence/evidence.tar.gz:manual/2026-07-26/evidence.tar.gz" \
            "6week-challenge/week-5/evidence/week5-evidence.tar.gz:manual/2026-07-26/week5-evidence.tar.gz"; do
  L="${pair%%:*}"; K="${pair##*:}"
  for ext in "" ".sig.bundle"; do
    aws s3api put-object --bucket "$B" --key "$K$ext" --body "$L$ext" >/dev/null
    echo "uploaded $K$ext"
  done
done
```

Expected: four `uploaded …` lines.

- [ ] **Step 7: Verify the new retention dates**

```bash
for k in manual/2026-07-26/evidence.tar.gz manual/2026-07-26/week5-evidence.tar.gz; do
  aws s3api get-object-retention --bucket grc-challenge-evidence-vault-f11fcaca --key "$k" \
    --query 'Retention.RetainUntilDate' --output text
done
```

Expected: two dates roughly 30 days in the future (about 2026-08-28).

- [ ] **Step 8: Confirm the pipeline still passes locally**

Run:
```bash
./verify-pipeline.sh
```

Expected: `12 passed, 0 failed, 0 skipped` and `PIPELINE PASS — every check ran and every check passed`.

- [ ] **Step 9: Commit**

```bash
git add 6week-challenge/week-6/terraform/variables.tf
git commit -m "feat(week-6): raise vault retention to 30 days for the CI verifier

verify-pipeline.sh checks that the vault's Object Lock retention is still in
the future. At one day that check went red every day, on pull requests that had
changed nothing, which makes a required check worthless: a signal that is red
for calendar reasons trains everyone to ignore it.

30 days is long enough that the check means something between runs and short
enough to stay a demo. It is not a retention policy and the documents still say
so — real records retention is measured in years.

Applied against the existing state: 0 added, 1 changed, 0 destroyed. The four
manual evidence objects were re-uploaded afterwards to inherit the new default,
since a bucket default applies only to new uploads. They are byte-identical to
the local copies, so hashes and signatures are unchanged; only the lock moved.

This is irreversible. COMPLIANCE retention extends but never shortens, so the
bucket cannot be destroyed until roughly 2026-08-28."
```

---

### Task 2: Update every document that states retention is one day

**Files:**
- Modify: `6week-challenge/week-6/README.md:135-138`
- Modify: `6week-challenge/week-6/ASSURANCE-BOUNDARY.md:90-108`
- Modify: `6week-challenge/week-6/PORTFOLIO-CASE-STUDY.md:210-212`
- Modify: `~/workdir/sevenbelow/www-sevenbelow/content/research/grc-engineering-pipeline.mdx:283-285` (different repo, do **not** commit there)

**Interfaces:**
- Consumes: the 30-day value applied in Task 1.
- Produces: no code interface. Later tasks do not depend on this.

The argument in each passage survives — 30 days is still not the years real records retention demands. Only the number and the teardown reasoning move.

- [ ] **Step 1: Update the README cost section**

In `6week-challenge/week-6/README.md`, replace:

```
retention expires — 24 hours at the default. Pennies in the meantime; the
constraint is timing, not money.
```

with:

```
retention expires — 30 days at the default. Pennies in the meantime; the
constraint is timing, not money.
```

- [ ] **Step 2: Update ASSURANCE-BOUNDARY section 4**

Replace the heading:

```
## 4. One day of Object Lock is a cost demo, not a retention policy
```

with:

```
## 4. Thirty days of Object Lock is a demo value, not a retention policy
```

Replace:

```
The vault is configured with `vault_retention_days = 1`. COMPLIANCE mode means
that day is real — the objects genuinely cannot be deleted by anyone, including
```

with:

```
The vault is configured with `vault_retention_days = 30`. COMPLIANCE mode means
those days are real — the objects genuinely cannot be deleted by anyone, including
```

Replace:

```
But real records-retention regulation is measured in years, not hours. SEC
```

with:

```
But real records-retention regulation is measured in years, not weeks. SEC
```

Replace:

```
One day was chosen so the demonstration could be torn down inside the
challenge window. Changing the number is a one-line edit; satisfying the
regulation is not. Saying otherwise would be exactly the kind of claim this
whole build exists to make unnecessary.
```

with:

```
The number is set by what the CI verifier needs, not by a regulation: the
pipeline checks on every pull request that retention is still in the future,
and a one-day lock made that check red for calendar reasons. It was one day
while the demonstration had to be torn down inside the challenge window.
Changing the number is a one-line edit; satisfying the regulation is not.
Saying otherwise would be exactly the kind of claim this whole build exists to
make unnecessary.
```

- [ ] **Step 3: Update the case study**

In `6week-challenge/week-6/PORTFOLIO-CASE-STUDY.md`, replace:

```
that the evidence is *correct*; and one day of Object Lock is a cost demo, not a
retention policy.
```

with:

```
that the evidence is *correct*; and thirty days of Object Lock is a demo value,
not a retention policy.
```

- [ ] **Step 4: Update the unpublished MDX**

In `~/workdir/sevenbelow/www-sevenbelow/content/research/grc-engineering-pipeline.mdx`, replace:

```
- **One day of Object Lock is a cost demo.** COMPLIANCE mode is real — a hard
```

with:

```
- **Thirty days of Object Lock is a demo value.** COMPLIANCE mode is real — a hard
```

Do **not** run any git command in `www-sevenbelow`. That repo deploys the live marketing site on push and is out of scope for this plan.

- [ ] **Step 5: Confirm no stale one-day claims remain in the repo**

Run:
```bash
grep -rn -e "24 hours" -e "One day of Object Lock" -e "one day of Object Lock" -e "vault_retention_days = 1" \
  --include="*.md" --include="*.tf" . | grep -v docs/superpowers
```

Expected: no output. Matches under `docs/superpowers/` are the spec and this plan describing the change and are correct as written.

- [ ] **Step 6: Commit**

```bash
git add 6week-challenge/week-6/README.md \
        6week-challenge/week-6/ASSURANCE-BOUNDARY.md \
        6week-challenge/week-6/PORTFOLIO-CASE-STUDY.md
git commit -m "docs(week-6): retention is 30 days now, in every place that said one

Raising vault_retention_days falsified four committed statements. A repo whose
argument is that you should write down what your controls do not prove cannot
leave its own numbers stale.

The argument in each passage is untouched, because it never depended on the
number: 30 days is still not the years SEC 17a-4, FINRA 4511(c) and CFTC
1.31(c) require, and Object Lock is still one of the three things those rules
ask for. ASSURANCE-BOUNDARY section 4 keeps its place on the list of limits.

What did change is the reason for the number. It used to be 'short enough to
tear down inside the challenge window'. It is now 'long enough that a per-PR
check of retention is not red for calendar reasons'. Recording the real reason
matters more than recording a tidy one.

The same edit is applied to the unpublished MDX in www-sevenbelow, which is not
committed here."
```

---

### Task 3: Add the verify-pipeline job

**Files:**
- Modify: `.github/workflows/grc-gate.yml` (append a third job after `grc-gate-oidc`)

**Interfaces:**
- Consumes: the 30-day retention from Task 1. Without it the job's `traverse.sh` leg fails on lapsed retention.
- Produces: a status check named `verify-pipeline`, which Task 4 adds to the required set. The check name is the job key, so it must be exactly `verify-pipeline`.

- [ ] **Step 1: Append the job**

Add at the end of `.github/workflows/grc-gate.yml`, at the same indentation as the existing `grc-gate-oidc:` job key:

```yaml
  # ---------------------------------------------------------------------------
  # verify-pipeline: run the repo's own verifier, in CI, on every pull request.
  #
  # verify-pipeline.sh is the single verdict this repo gives on itself — twelve
  # checks from `terraform validate` through to a full profile-to-evidence
  # traversal. Until now it only ran when a person remembered to run it, and
  # three bugs in the week-6 session were caught solely by running it on a
  # second machine. All three had the same shape: something reported success
  # while verifying nothing.
  #
  # The job runs WITH credentials on purpose. The two vault checks read Object
  # Lock retention, and without credentials they report `skipped` — which the
  # script correctly treats as honest, and which exits 0. A job that accepted
  # that would go green while verifying less than it claims, which is the exact
  # failure `oscal-from-conftest.py`'s mapping guard exists to prevent. So the
  # credentials are what make the check mean something, and the explicit
  # `0 skipped` assertion below is what keeps it meaning something when a tool
  # silently stops installing.
  #
  # The role is read-only. Writes to the vault come from a bucket policy that
  # grants PutObject alone, so this job cannot modify the evidence it verifies.
  # ---------------------------------------------------------------------------
  verify-pipeline:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write   # required for the OIDC exchange; no stored AWS keys
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_wrapper: false

      # Same pinned version as the gate above, from the same workflow-level env.
      # Deliberately not a second pin site: tool versions are already pinned in
      # too many places in this repo.
      - name: Install Conftest ${{ env.CONFTEST_VERSION }}
        run: |
          set -euo pipefail
          curl -sSfL \
            "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz" \
            -o conftest.tar.gz
          tar -xzf conftest.tar.gz conftest
          sudo install -m 0755 conftest /usr/local/bin/conftest
          conftest --version

      - name: Set up Python for trestle
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install compliance-trestle
        run: pip install --quiet compliance-trestle==4.2.0

      - name: Install Cosign
        uses: sigstore/cosign-installer@v4

      # Read-only. ReadOnlyAccess covers s3:GetObjectRetention, which is all the
      # vault checks need.
      - name: Configure AWS credentials (OIDC, read-only, no stored keys)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_GATE_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION || 'us-east-1' }}

      # The same command a human runs. No CI-only flags: a verifier that behaves
      # differently in CI is a second thing to trust.
      - name: Run the full verification
        env:
          EVIDENCE_VAULT_BUCKET: ${{ vars.EVIDENCE_VAULT_BUCKET }}
        run: |
          set -o pipefail
          ./verify-pipeline.sh 2>&1 | tee verify-pipeline.log

      # An absent verdict is not a passing verdict.
      #
      # verify-pipeline.sh exits 0 when checks are SKIPPED, which is right for a
      # laptop with a partial toolchain and wrong for CI, where a skip means an
      # install step broke. Trusting the exit code alone would let this job go
      # green having run six checks instead of twelve. So the summary line is
      # parsed and a non-zero skip count fails the build.
      - name: Assert nothing was skipped
        run: |
          set -euo pipefail
          summary="$(grep -E '^[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped$' verify-pipeline.log | tail -1 || true)"
          if [ -z "$summary" ]; then
            echo "::error::no summary line found — verify-pipeline.sh did not run to completion"
            exit 1
          fi
          skipped="$(printf '%s\n' "$summary" | awk '{print $5}')"
          echo "summary: $summary"
          if [ "$skipped" != "0" ]; then
            echo "::error::$skipped check(s) skipped. With credentials present nothing should skip; a skip means a tool failed to install and this run verified less than it claims."
            exit 1
          fi

      - name: Upload the transcript
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: verify-pipeline-transcript
          path: verify-pipeline.log
          if-no-files-found: error
```

- [ ] **Step 2: Check the workflow parses**

Run:
```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/grc-gate.yml')); print('jobs:', list(d['jobs'])); print('verify-pipeline steps:', len(d['jobs']['verify-pipeline']['steps']))"
```

Expected: `jobs: ['grc-gate', 'grc-gate-oidc', 'verify-pipeline']` and `verify-pipeline steps: 10`.

If `yaml` is not installed, run `pip install --quiet pyyaml` first.

- [ ] **Step 3: Verify the skip-assertion logic against real output**

Prove the parser works before trusting it in CI. Run locally:

```bash
./verify-pipeline.sh > /tmp/vp.log 2>&1 || true
summary="$(grep -E '^[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped$' /tmp/vp.log | tail -1)"
echo "summary: [$summary]"
echo "skipped: [$(printf '%s\n' "$summary" | awk '{print $5}')]"
```

Expected: `summary: [12 passed, 0 failed, 0 skipped]` and `skipped: [0]`.

The summary line carries no ANSI colour (`verify-pipeline.sh:204` is a plain `printf`), which is why an anchored grep matches it. If the grep returns empty, stop and investigate rather than loosening the pattern — a pattern that matches nothing would make the assertion silently vacuous, which is the failure mode this whole job exists to catch.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/grc-gate.yml
git commit -m "feat(ci): run verify-pipeline.sh on every pull request

The repo's own twelve-check verdict has only ever run when somebody remembered
to run it. Three bugs last session were caught solely by running it on a second
machine, all three shaped the same way: something reported success while
verifying nothing. One had traverse.sh walking zero controls and printing
TRAVERSAL COMPLETE.

Two details matter more than the rest.

It runs WITH credentials. The vault checks read Object Lock retention, and
uncredentialed they report skipped — honest, and exit 0. A job that accepted
that would be green while verifying less than it claims.

And it asserts the skip count is zero rather than trusting the exit code. A
skipped check exits 0 by design (verify-pipeline.sh:214-218), which is correct
for a laptop with a partial toolchain and wrong for CI, where a skip means an
install step broke. Without the assertion this job could go green having run
six checks instead of twelve — the same silence the converter's mapping guard
exists to catch, reproduced in the build that is supposed to catch it.

The role is read-only; vault writes come from a bucket policy granting
PutObject alone, so the job cannot modify the evidence it verifies.

Not yet a required check. That comes after a green run."
```

- [ ] **Step 5: Push and open a pull request**

```bash
git push -u origin ci-verify-pipeline
gh pr create --base main --head ci-verify-pipeline \
  --title "ci: run verify-pipeline.sh on every pull request" \
  --body "Runs the repo's own twelve-check verifier in CI, credentialed so nothing skips, and asserts a zero skip count rather than trusting the exit code.

Raises vault Object Lock retention from 1 day to 30 so the preservation check is not red for calendar reasons, and updates every document that stated the old value.

Design: \`docs/superpowers/specs/2026-07-28-verify-pipeline-ci-design.md\`
Plan: \`docs/superpowers/plans/2026-07-28-verify-pipeline-ci.md\`

Not yet added to the required-checks ruleset — that follows a green run."
```

- [ ] **Step 6: Watch the run and confirm it is genuinely green**

```bash
gh run watch "$(gh run list --branch ci-verify-pipeline --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

Then confirm the assertion actually saw a full run:

```bash
gh run view "$(gh run list --branch ci-verify-pipeline --limit 1 --json databaseId --jq '.[0].databaseId')" \
  --log --job verify-pipeline 2>/dev/null | grep -E "summary: [0-9]+ passed"
```

Expected: `summary: 12 passed, 0 failed, 0 skipped`.

**A green job with a summary showing skips means the assertion is broken, not that the run was fine.** Investigate before continuing to Task 4.

---

### Task 4: Make verify-pipeline a required status check

**Files:**
- Modify: repository ruleset `grc-gate-required` (id `18644393`) via the GitHub API. No repo files change.

**Interfaces:**
- Consumes: a green `verify-pipeline` check from Task 3. Do not start this task until Task 3 Step 6 passed.
- Produces: nothing later tasks depend on. This is the final task.

- [ ] **Step 1: Read the current ruleset**

```bash
gh api repos/sevenbelowllc/grc-engineering-club/rulesets/18644393 > /tmp/ruleset-before.json
python3 -c "import json;d=json.load(open('/tmp/ruleset-before.json'));print(json.dumps([r for r in d['rules'] if r['type']=='required_status_checks'],indent=2))"
```

Expected: one rule listing a single context, `grc-gate`.

- [ ] **Step 2: Build the updated rules payload**

```bash
python3 - <<'PY' > /tmp/ruleset-after.json
import json
d = json.load(open('/tmp/ruleset-before.json'))
for r in d['rules']:
    if r['type'] == 'required_status_checks':
        ctxs = r['parameters']['required_status_checks']
        if not any(c['context'] == 'verify-pipeline' for c in ctxs):
            ctxs.append({'context': 'verify-pipeline'})
json.dump({'rules': d['rules']}, open('/tmp/ruleset-after.json','w'), indent=2)
print(json.dumps(d['rules'], indent=2))
PY
```

Expected: the printed rules show `required_status_checks` containing both `grc-gate` and `verify-pipeline`.

- [ ] **Step 3: Apply the ruleset update**

```bash
gh api --method PUT repos/sevenbelowllc/grc-engineering-club/rulesets/18644393 \
  --input /tmp/ruleset-after.json
```

- [ ] **Step 4: Verify both contexts are required**

```bash
gh api repos/sevenbelowllc/grc-engineering-club/rules/branches/main \
  --jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context'
```

Expected: two lines, `grc-gate` and `verify-pipeline`.

- [ ] **Step 5: Confirm the open PR reflects the new requirement**

```bash
gh pr view --json statusCheckRollup --jq '[.statusCheckRollup[] | {name, conclusion}]'
```

Expected: `grc-gate`, `grc-gate-oidc` and `verify-pipeline`, all `SUCCESS`.

- [ ] **Step 6: Record the change**

There is no repo file to commit for a ruleset change, so record it where the repo already records enforcement — append to the existing enforcement notes in `6week-challenge/week-6/SUBMISSION.md` under the checklist:

```markdown
- [x] `verify-pipeline` runs on every pull request and is a required status
      check — the twelve-check verdict now blocks the merge instead of waiting
      for somebody to remember to run it
```

Then:

```bash
git add 6week-challenge/week-6/SUBMISSION.md
git commit -m "docs(week-6): record verify-pipeline as a required check

A ruleset change leaves no file in the repository, which means the strongest
enforcement statement the repo makes would otherwise exist only in GitHub
settings where no reader can see it. The checklist is where this repo records
what is enforced, so it goes there.

The gate now blocks a merge on the full twelve-check verdict, not just the
three policy namespaces."
git push
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Credentials — run with OIDC | Task 3 Step 1 (`configure-aws-credentials`) |
| Retention 1 → 30 | Task 1 Steps 1-5 |
| Re-upload manual objects | Task 1 Steps 6-7 |
| Enforcement — required check | Task 4 |
| Placement — third job in grc-gate.yml | Task 3 Step 1 |
| IAM — no change | Global Constraints; no task touches IAM |
| Failure semantics — assert 0 skipped | Task 3 Step 1 (`Assert nothing was skipped`), verified Step 3 and Step 6 |
| Documentation — five sites | Task 2 Steps 1-4 (four sites in-repo plus the MDX) |
| Sequencing — ruleset last | Task order; Task 4 Interfaces block states the dependency |
| Out of scope — composite action, schedule, jq matrix | No task; intentionally absent |

**Placeholder scan:** No TBD/TODO. Every edit shows exact before and after text. Every verification step names its command and expected output.

**Type consistency:** The status-check context name `verify-pipeline` is used identically in Task 3 (job key) and Task 4 (ruleset context). The bucket, role ARN and account id match the Global Constraints throughout. The summary-line field index (`awk '{print $5}'`) is the same in Task 3 Step 1 and Step 3.

**One known gap, carried from the spec deliberately:** `ubuntu-latest` ships jq 1.7, so this job does not cover the jq 1.6 case that commit `54c1050` caught. Recorded in the spec's Out of Scope section rather than fixed.
