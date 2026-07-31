# GRC Engineering Club

A community for practitioners who treat **Governance, Risk, and Compliance (GRC)** as an engineering discipline — building, automating, and measuring compliance the way we build software.

---

## 📦 In this repo: a working compliance pipeline

**[`6week-challenge/`](6week-challenge/)** — six weeks of the GRC Engineering
Club challenge, built as one system rather than six exercises.

It provisions AWS infrastructure that satisfies NIST 800-53 controls, proves
those controls with policy-as-code, blocks pull requests that break them, signs
the resulting evidence, preserves it where nobody can delete it, watches the
running account, and publishes an OSCAL control mapping an assessor can traverse
without talking to anyone.

```bash
./verify-pipeline.sh   # every eligibility check, one verdict
./traverse.sh          # profile → component → evidence → CHAIN INTACT
```

**With nothing installed**, `verify-pipeline.sh` reports `PIPELINE INCOMPLETE` and
names every check it could not run. That is the honest answer, and it is not a
pass — it is the script declining to claim a result it did not obtain. Two
transcripts of full runs are committed and readable without installing anything:
[macOS](6week-challenge/week-6/evidence/pipeline-verification.txt) and
[Linux](6week-challenge/week-6/evidence/pipeline-verification-linux.txt). The same
command runs on [every pull request](.github/workflows/grc-gate.yml) with the full
toolchain, and the build fails if even one check skips.

**To run it yourself**, the checks need these. Nothing is installed for you — a
verifier that modifies the machine it is auditing has traded away the thing it
was built to establish.

| Tool | Enables | Install |
|---|---|---|
| `jq` | the traversal graph walk | `brew install jq` / `apt install jq` |
| [`cosign`](https://github.com/sigstore/cosign) | signature + identity verification (checks 4, 6) | `brew install cosign` |
| [`conftest`](https://www.conftest.dev/) | the policy gate, both directions | `brew install conftest` |
| `compliance-trestle` | OSCAL schema validation | `pip install compliance-trestle` |
| `terraform` | `validate` and plan regeneration | `brew install terraform` |
| `aws` + credentials | Object Lock retention on the vault | private by design; expected to skip |

`terraform validate` additionally needs an initialised working directory, and the
script will **not** run `terraform init` for you — that is a several-hundred-megabyte
provider download on someone else's machine. Run `terraform init` in the week
directories yourself if you want those checks to execute.

| | |
|---|---|
| **The build, week by week** | [6week-challenge/README.md](6week-challenge/) |
| **The capstone** | [week-6](6week-challenge/week-6/) — OSCAL, the traversal, the case study |
| **What it does *not* prove** | [ASSURANCE-BOUNDARY.md](6week-challenge/week-6/ASSURANCE-BOUNDARY.md) |
| **The interesting bit** | [conftest verdicts → OSCAL assessment-results](6week-challenge/week-6/assessment-results.md) |

Every claim in it is checkable by running something. Nothing needs an AWS
account, and nothing needs the author's cooperation.

---

## What is GRC Engineering?

GRC Engineering is the practice of applying software-engineering principles to governance, risk, and compliance work. Instead of static spreadsheets, point-in-time audits, and manual evidence collection, GRC engineers build **systems** that make compliance continuous, testable, and version-controlled:

- **Compliance as code** — controls, policies, and frameworks expressed in code and config rather than documents.
- **Continuous control monitoring** — automated checks that prove controls are working, all the time, not once a year.
- **Evidence automation** — pipelines that collect, store, and timestamp audit evidence without human copy-paste.
- **Risk quantification** — treating risk as data: measurable, trended, and acted on.

## What the club is for

The GRC Engineering Club is a place to:

- **Share patterns** — reusable approaches for control mapping, evidence collection, policy-as-code, and audit automation.
- **Compare tooling** — what works (and what doesn't) across the GRC tooling landscape.
- **Trade war stories** — real lessons from audits, framework adoptions (SOC 2, ISO 27001, HIPAA, FedRAMP, etc.), and automation projects.
- **Learn together** — resources for engineers moving into GRC and GRC professionals leveling up their technical skills.

## Who it's for

- Security and compliance engineers automating their programs
- Software engineers who own controls in their pipelines
- GRC analysts and auditors who want to work closer to the systems they assess
- Anyone curious about making compliance less manual and more reliable

## Getting involved

This repository is **public and read-only** — it's maintained as the club's reference space. Contributions, suggestions, and discussion are coordinated by the maintainer.

## Topics

`grc` · `governance` · `risk` · `compliance` · `compliance-as-code` · `security` · `audit-automation` · `continuous-controls`

---

*Maintained by [Seven Below](https://github.com/sevenbelowllc).*
