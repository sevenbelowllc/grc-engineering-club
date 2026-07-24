# Week 6: Speak the Auditor's Language

**GRC Engineering Club** · Jul 21, 2026

You have a pipeline that enforces controls, proves them with policy, gates them on every pull request, signs the evidence, and watches the account. There is one gap left. All of that proof lives in your formats: Terraform, Rego, JSON artifacts, signed bundles.

An assessor lives in a different world, and the bridge between the two is **OSCAL**, NIST's machine-readable format for controls and evidence. This week you build that bridge. Then you write the case study that turns six weeks of work into the centerpiece of your portfolio.

**This is the finish line.** Two builds:

1. An OSCAL control mapping
2. The case study that presents the whole pipeline as one system

> **Starter code:** grab `week-6-starter.zip` attached to this post. It has a README with the trestle steps and a `PORTFOLIO-CASE-STUDY.md` template. The OSCAL is yours to author with trestle, which generates valid skeletons for you to fill in. The template is a frame, not the picture.

## What OSCAL actually buys you

Forget the acronym for a second. The thing OSCAL gives you is **traversal**. An assessor starts at a control catalog, follows a profile to the subset of controls in scope, follows a component to how each control is implemented, and follows an evidence link to the actual proof. No meeting, no screenshot request, no email thread. They read the document and follow the links. The audit becomes a graph traversal:

```
catalog → profile → component → evidence URI → verified bundle
```

You are going to write the smallest real version of that. One component that describes your pipeline, a profile that selects the controls it covers, and evidence links that point at the signed bundles you produced in week 4. When it works, someone reads your control mapping, clicks through to a signed bundle, verifies it, and confirms your SC-28 claim without ever talking to you.

## What you are building

Two OSCAL documents, both authored with trestle and both validating clean.

### 1. A component definition

Describes your pipeline. One `implemented-requirement` per control you genuinely satisfied: **SC-28, AC-3, AU-3, CM-6**. Each one:

- says in plain language how your infrastructure satisfies the control,
- carries a prop naming the Terraform resource that does the work, and
- carries a `links` entry with `rel: evidence` whose `href` points at your signed bundle from week 4.

The `source` is the public NIST 800-53 Rev 5 catalog.

### 2. A profile

Selects exactly those control IDs from the catalog and nothing else. The profile is the statement of what you are claiming. Four controls, four IDs, no padding.

## Prerequisites

- Your week 4 signed bundle, or your week 4 vault object, reachable by a URL or path. This is what your evidence links point at.
- Your week 4 `verify-evidence.sh`, working. You will run it again at the end.
- Python 3 and pip. trestle is a Python package.
- 45 to 60 minutes.

## Cost

**Free.** OSCAL is JSON sitting in your repo. Nothing to deploy, nothing to tear down.

## Build it

Install trestle and initialize a workspace. Then work through both documents. The README in the starter has the exact invocations.

1. **Generate the component skeleton:**

   ```sh
   trestle create -t component-definition -o my-pipeline -x json
   ```

   Then fill it in. For each control, write the `implemented-requirement`, add the prop that names the Terraform resource (the encryption resource for SC-28, the public access block for AC-3, and so on), and add the `rel: evidence` link to your signed bundle. Set `source` to the NIST 800-53 Rev 5 catalog URL.

2. **Generate the profile:**

   ```sh
   trestle create -t profile
   ```

   List your four control IDs under `include-controls`.

## Run it and validate

You want `VALID` on both. The OSCAL schema is strict and verbose, so expect to fix a few missing fields before it goes clean. That strictness is the point. A document that validates is a document a machine can traverse.

## Prove the traversal

This is the moment the whole challenge pays off. Pick one control in your component — SC-28 is the clean one. Follow its evidence `href` to the vault or the signed bundle. Run your week 4 `verify-evidence.sh` against it.

When it prints `CHAIN INTACT`, the entire chain is connected end to end: a machine-readable control statement, an evidence link, a signed bundle, a passing verification. That is what engineered assurance means, and you just built the smallest complete version of it.

## The capstone: your portfolio case study

The OSCAL is the last technical brick. The case study is what makes the pile of bricks a building.

Fill in `PORTFOLIO-CASE-STUDY.md` and put it at the top of your portfolio. It presents all six weeks as one pipeline: what it is, the six stages, and the proof.

- Link the repo.
- Link the green pull request and the red one.
- Link or screenshot the `opa test` run, the `CHAIN INTACT` verification, and the `trestle validate` VALID output.

Lead with evidence, not adjectives. A hiring manager should understand what you built in 60 seconds and be able to click through to proof of every claim.

Then two short, honest sections: what you would do next with more time, and the one non-obvious thing that clicked. Those two are where you show judgment, and judgment is what the job is actually about.

When that page is live, you have something almost nobody applying for these roles has: a public, working, verifiable demonstration that you can build the thing, not just talk about it.

## Done when

- [ ] `trestle validate` returns `VALID` for the component and the profile.
- [ ] At least one evidence link resolves to a real signed bundle, and running `verify-evidence.sh` against it prints `CHAIN INTACT`.
- [ ] The case study is published at the top of your portfolio and links to the repo.

## On GCP?

OSCAL is cloud-agnostic by design. The controls are NIST controls regardless of cloud. Your implemented-requirements name `google_storage_bucket` and its siblings instead of the AWS resources, and your evidence links point at your bundles. The document looks the same, which is the entire reason this format exists.

## Make it a portfolio piece

This whole week is the portfolio piece. The OSCAL directory and the case study are the capstone of the challenge. Ship them both, then post your finished portfolio, the entire six-week build presented as one system.

Post it on LinkedIn. Tag GRC Engineering Club, use **#GRCEngClubChallenge**, and tell people what you built across six weeks. This is the post that gets seen, because it is proof, and proof is rare.

## Common snags

| Snag | Fix |
|------|-----|
| UUID regex errors | OSCAL wants v4 UUIDs and rejects anything else. Do not hand-write them. Generate each one with `python3 -c "import uuid; print(uuid.uuid4())"`. |
| `oscal-version` mismatch | The catalog, profile, and component all have to share an `oscal-version`. Let trestle pin it and do not mix. Check yours with `trestle version`. |
| Validation fails on missing fields | The schema is verbose. Use trestle to inspect what a model requires instead of guessing. |
| Evidence links that go nowhere | OSCAL does not check that your links resolve. A broken link is a useless attestation. Follow your own references and confirm they land. |

---

That is the pipeline. Six weeks ago you had a bucket. Now you have a system that builds compliant infrastructure, proves it, gates it, signs it, monitors it, and maps it to controls an assessor can verify without you in the room.

## The rewards come next!

**$1,000 prize pool for finishers.**

| Place | Prize | How it's decided |
|-------|-------|------------------|
| 1st | $500 | An AI evaluation of your submitted repo picks the winner. It looks at pipeline completeness, evidence quality, and the strength of your case study. |
| 2nd | $250 | Random raffle from all finishers |
| 3rd | $250 | Random raffle from all finishers |

You are eligible by finishing the challenge. That means the full pipeline passes end to end: `terraform validate`, `conftest`, `trestle validate`, `cosign verify`, vault upload. If your "Done when" list above is checked, you qualify.

**Submit your repo at [cert.grcengclub.com/challenge](https://cert.grcengclub.com/challenge) before July 31st.** Winners announced the week after the challenge ends.
