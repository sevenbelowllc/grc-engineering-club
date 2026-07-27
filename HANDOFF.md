# Session handoff — week 6 capstone

> **Delete this file before merging to `main`.** It is session scaffolding, not a
> deliverable, and a judged repo should not contain a to-do list. One commit:
> `git rm HANDOFF.md && git commit -m "chore: drop the session handoff"`.

Written 2026-07-27T04:38Z. Branch `week6-challenge`, **20 commits, none pushed**.
Challenge deadline **2026-07-31** — four days.

---

## ⚠️ Do these BEFORE you leave this machine

Three things live only on this laptop. A `git push` does not carry any of them.

### 1. Push the branch, or the work is stranded

```bash
git push -u origin week6-challenge
```

Twenty commits. Everything below assumes this happened.

### 2. Copy the Terraform state — you cannot destroy the vault without it

```
6week-challenge/week-6/terraform/terraform.tfstate     (18 KB, gitignored by .gitignore:150)
```

This is the **only** record of the 10 applied AWS resources — the GitHub OIDC
provider, the `grc-gate-oidc` role, and the evidence vault bucket. It is
correctly gitignored (state in git is bad practice and it holds resource detail),
so it will not travel with the push. Move it over a secure channel, or accept
that teardown has to happen from this machine.

Losing it does not break anything that is committed — every claim in the repo
verifies without it — but it does mean `terraform destroy` can only be run here.

### 3. Copy the unpublished case-study MDX

```
~/workdir/sevenbelow/www-sevenbelow/content/research/grc-engineering-pipeline.mdx   (17 KB)
```

Untracked in a *different* repo, so it is invisible to this branch's push. It is
the site version of `6week-challenge/week-6/PORTFOLIO-CASE-STUDY.md` — same
content, absolute GitHub links, plus the mermaid pipeline diagram. Frontmatter
already validated against `www-sevenbelow/src/lib/research.ts`.

If you lose it, it is regenerable from the committed markdown in about ten
minutes. Not a disaster, just annoying.

Also on this machine and easily recreated: a Docker daemon left running (quit
Docker Desktop when convenient), and the week-6 LinkedIn draft — reproduced in
full at the bottom of this file so it travels.

---

## Where things stand

The repo work is done. Everything remaining needs a human.

```
./verify-pipeline.sh     macOS   12 passed, 0 failed, 0 skipped
                         Linux   10 passed, 0 failed, 1 skipped (no AWS CLI in the container)
./traverse.sh            4/4 controls, profile → verified evidence, all four legs
```

| | |
|---|---|
| OSCAL | 5 documents, all `trestle validate` VALID |
| Evidence | 2 signed bundles, both in a COMPLIANCE-mode Object Lock vault |
| CI | validates OSCAL and emits per-run assessment-results — **never yet run** |
| Case study | written, in-repo and as MDX — **not published** |
| Submission | **not made** |

---

## What is next, in dependency order

### 1. Read the case study

`6week-challenge/week-6/PORTFOLIO-CASE-STUDY.md`. You asked to review before
anything ships. Nothing below should move until you are happy with it.

### 2. Sign the OSCAL — needs your browser

```bash
cd 6week-challenge/week-6 && ./sign-oscal.sh
```

cosign keyless opens a browser once for OIDC. Sign in with **Google
(dkramer@sevenbelow.com)** — that is the identity the week-5 bundle used and the
one the docs tell verifiers to pin.

It writes three files to `week-6/evidence/`: `oscal-documents.tar.gz`, its
`.sha256`, and `.sig.bundle`. Commit all three.

This is the last technical gap in week 6. Right now the OSCAL documents are the
only artifacts in the pipeline that are **not** tamper-evident — which matters,
because a signed evidence bundle behind an unsigned index is a strong lock on a
door somebody can move.

Verify afterwards:

```bash
EXPECT_ISSUER='https://accounts.google.com' \
EXPECT_IDENTITY='^dkramer@sevenbelow\.com$' \
  ../week-4/verify-evidence.sh evidence/oscal-documents.tar.gz
```

### 3. Merge to `main`

Everything downstream depends on it. The MDX's proof links all point at
`blob/main/…` and **404 until the merge lands**, so publishing before merging
produces an article full of dead evidence links.

### 4. Set two repo variables, then open a PR

Settings → Secrets and variables → Actions → **Variables** (not secrets; neither
is confidential):

| Variable | Value |
|---|---|
| `AWS_GATE_ROLE_ARN` | `arn:aws:iam::<account>:role/grc-gate-oidc` |
| `EVIDENCE_VAULT_BUCKET` | `grc-challenge-evidence-vault-f11fcaca` |

Get the exact ARN from `terraform output gate_role_arn` (needs the state file) or
from the IAM console.

Then open any PR. It is worth more than it looks — it is the first real exercise
of three things that have only ever run locally or in simulation:

- the vault upload step (dormant until both variables exist)
- `trestle validate -a` in CI
- the per-run conftest → OSCAL assessment-results conversion

Expect: a green gate, a PR comment reporting OSCAL validity alongside the
namespace table, and a signed bundle in the vault under `runs/<run_id>/`.

That is the last unchecked box in `week-6/SUBMISSION.md`.

### 5. Publish the case study

`www-sevenbelow`, `content/research/grc-engineering-pipeline.mdx` → renders at
`/resources/research/grc-engineering-pipeline`. Preview with `npm run dev` first.

Pushing there deploys the live marketing site via Vercel. **After** step 3.

### 6. Post and submit

LinkedIn draft is at the bottom of this file. Submit the repo at
**cert.grcengclub.com/challenge before 2026-07-31.**

---

## Environment needed on the new machine

| Tool | Version used here | Notes |
|---|---|---|
| bash | 3.2 (macOS) / 5.2 verified | scripts target both |
| python | 3.11.15 | `trestle` lives in this interpreter |
| compliance-trestle | 4.2.0 (OSCAL 1.2.1) | `pip install compliance-trestle==4.2.0` |
| terraform | 1.15.8 local / 1.9.8 in the container | any ≥ 1.6 |
| conftest | 0.68.2 pinned in CI | a local `dev` build also works |
| cosign | 3.1.2 | `sigstore/cosign-installer@v4` in CI |
| jq | **1.6 or 1.7** | filters were fixed to parse on both |
| aws-cli | 2.x, credentials for the challenge account | only needed for the vault leg |
| docker | optional | only used to prove Linux portability |

`verify-pipeline.sh` reports missing tools as **SKIP**, named — it never
silently passes. A partial toolchain gives you a partial but honest run.

---

## Traps worth knowing about

**Object Lock is holding the bucket.** Retention releases
**2026-07-28T02:26:45Z** (~22h from writing). Until then `terraform destroy`
fails on the bucket — by design, that is the WORM proof. After that you have a
~3-day window before the deadline if you want the account torn down. The
evidence in the repo verifies either way; only the `preservation:` leg needs the
vault alive.

**Two directories create the same IAM role.** `week-3/oidc/iam-oidc.tf` and
`week-6/terraform/oidc.tf` both define `grc-gate-oidc`. Only week-6's has been
applied and only week-6's should ever be. There is a banner on the week-3 file
saying so.

**Never run `rebuild-oscal.sh` without re-signing.** It mints fresh UUIDs, which
invalidates any signature over the documents and re-points the assessment
results' `implementation-statement-uuid` references.

**Keep the shared shell helpers byte-identical.** `fail`, `sha256_file`,
`write_sha256_sidecar`, `read_sha256_sidecar` and the reporting vocabulary
(`c_bold`/`c_green`/`c_red`/`c_grey`/`rule`/`title`/`section`/`ok`/`bad`/`skip`/
`need`) are duplicated across scripts on purpose so each week directory stands
alone. Change one, change all. Even padding a definition for alignment breaks
the property — that happened once this session and the digest check caught it.

**jq 1.6 vs 1.7.** `.foo[].["key"]` parses on 1.7 and is a syntax error on 1.6.
Ubuntu 22.04 and Debian 12 ship 1.6. Write `.foo[] | .["key"]`.

---

## Deferred cleanup — after 2026-07-31, not before

Deliberately not done, because it would rewrite paths that signed evidence and
commit-pinned OSCAL documents describe, four days from the deadline.

1. **A CI job running `./verify-pipeline.sh` on `ubuntu-latest`.** Highest value
   on this list by a distance — it would have caught both of this session's bugs
   on the first push, including the one where `traverse.sh` walked zero controls
   and reported success.
2. Six Terraform root modules, two of them superseded and conflicting.
3. `week-1/solution` ≡ `week-3/terraform` (byte-identical), and
   `week-2/policies` ≡ `week-3/policies`, and `week-1/verify.sh` ≡
   `week-1/solution/verify.sh`.
4. Tool versions pinned in eight places; commit pin `1d97be7` hardcoded in five.
5. Unit tests for `oscal-from-conftest.py` — its guards are currently proven by a
   committed transcript, not a test.
6. The AWS Organizations landing zone (project #2). Scoped and deliberately not
   started; reasoning is in the case study's "What I would build next".

---

## Week-6 LinkedIn draft

Not committed anywhere else — reproduced here so it survives the machine change.
Replace the case-study URL once published, tag the GRC Engineering Club company
page properly (an @ mention, not just the hashtag), and consider attaching the
`verify-pipeline.sh` terminal output as an image: 12/12 green reads better than
a description of 12/12 green.

```text
Six weeks ago I had an S3 bucket.

Today I have a pipeline where a stranger can verify my NIST 800-53 control
claims without ever talking to me.

Here's the thing I actually wanted to test: can compliance evidence work like a
software supply chain instead of like a shared drive full of screenshots?

Turns out yes, and the tooling already exists.

The six stages:

1. Terraform baseline that satisfies SC-28, AC-3, CM-6
2. Rego policies that make those controls executable
3. A CI gate that blocks the merge — not a dashboard that reports it later
4. Signed evidence: SHA-256 + keyless cosign + Rekor + S3 Object Lock
5. CloudTrail and Security Hub watching the running account
6. OSCAL — the control mapping an assessor can traverse by following links

Three things I didn't expect to learn:

→ Policy that runs BEFORE apply has to reason about intent, not state.
At plan time my bucket's name is "grc-challenge-dev-data-${random_id.hex}" — a
value that doesn't exist yet. A rule that matches on the name can't evaluate the
plan at all, so it silently passes. Match on the symbolic address instead.

→ "Intact, authentic, timely, undeletable" are FOUR properties needing four
mechanisms. A hash proves the bytes didn't change and says nothing about who
made them. A signature proves who and nothing about when. Rekor proves when and
doesn't stop deletion. Object Lock stops deletion and proves nothing about
content. Most programs collapse all four into "we have evidence" and find out
during the audit which one they were missing.

→ An absent verdict is not a passing verdict.
My favourite eight lines of the whole build check that every policy the OSCAL
CLAIMS gates a control actually reported a result. Because if a policy file
quietly stops loading, conftest returns one fewer entry and exit code 0. Green
gate. Valid document. No mention of SC-28. Nothing turns red.

That's how automated compliance rots — not with a failure, with a silence.

One thing I deliberately did NOT do: write a plan-time rule for AU-3. A plan can
show a CloudTrail trail will be created. It can't show the trail is delivering
records. A fourth green check that attests to nothing is worth less than an
honest gap, so AU-3's evidence is captured runtime output and the OSCAL says why.

The repo also ships a document listing seven things the pipeline does NOT prove.
An assessor's first question about any automated control is "what does it miss?"
The answer's the same whoever writes it. Only question is whether it came from
you or from them.

Everything is public and everything is runnable:

  git clone https://github.com/sevenbelowllc/grc-engineering-club
  cd grc-engineering-club && ./verify-pipeline.sh

12 checks. No AWS account needed. No cooperation from me needed.

That was the point.

Repo: https://github.com/sevenbelowllc/grc-engineering-club
Full write-up: [case study URL once published]

Thanks to GRC Engineering Club for building a challenge that made me ship
instead of read.

#GRCEngClubChallenge #GRCEngineering #ComplianceAsCode #OSCAL #DevSecOps #AWS
```

---

## Session log — what changed, newest first

```
1860d15  refactor(scripts): one reporting vocabulary across traverse and verify-pipeline
c688961  refactor(traverse): use the same fail() as every other script
e45aec8  refactor(scripts): make the sidecar operation a function too, not just the primitive
bf58adb  refactor(scripts): one canonical hashing helper, used identically everywhere
54c1050  fix: target Linux and generalized bash, and prove it by running there
b82800c  docs: note where weeks 3 and 4 were superseded, without back-editing them
9d835af  fix(traverse): don't abort on bash 3.2 when there is no vault to check
3ba08c7  docs: finish week 4's README and add the missing week 6 submission
865a1aa  docs(week-6): the case study — six weeks presented as one system
91d2594  docs: give the repo a front door, a control matrix, and a stated boundary
2ecefa6  feat(ci): gate on OSCAL validity and emit assessment-results per run
d401eb9  feat: make "the pipeline passes" a command instead of a claim
0707d27  feat(week-6): OSCAL control mapping, and a converter that keeps it honest
7f1ee29  fix(week-5): print the issuer the bundle was actually signed with
a212602  feat(week-6): capstone terraform — keyless CI identity and immutable evidence vault
1b53600  fix(ci): give the grc-gate job AWS credentials for the vault upload
9c2845c  docs(week-2,week-3): finish the starter README and recover the signed gate verdict
3c760d7  fix(week-5): write the sha256 sidecar with a relative path, not an absolute one
5d471ca  chore: remove draft notes and the paywalled brief from the public repo
```

Three bugs were found by running the code somewhere other than where it was
written, and all three had the same shape — **something reported success while
verifying nothing**. That is worth remembering more than any individual fix.
