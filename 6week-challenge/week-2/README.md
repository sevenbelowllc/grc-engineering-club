# Week 2 — Make the Rules Executable

Three NIST 800-53 controls, expressed as [Rego](https://www.openpolicyagent.org/docs/latest/policy-language/)
policies that read a Terraform plan and return the same verdict every time, in
milliseconds. Week 1 produced a compliant bucket; "compliant" was still a claim a
human had to vouch for. This week replaces the human with code.

| Control | Policy | Denies when |
|---|---|---|
| **SC-28** — Protection of Information at Rest | `sc28_encryption_aws.rego` | an `aws_s3_bucket` has no matching server-side encryption configuration |
| **AC-3** — Access Enforcement | `ac3_no_public_aws.rego` | the public access block is missing, or any of its four flags is not `true` |
| **CM-6** — Configuration Settings | `cm6_required_tags_aws.rego` | a *taggable* resource is missing `Project`, `Environment`, `ManagedBy`, or `ComplianceScope` |

**Status: 6/6 unit tests passing**, and the same policies gate the real week-1 plan —
green against the compliant plan, and SC-28 correctly fails against a plan with the
encryption blocks removed, naming both buckets and the remediation.

## What's here

| Path | Purpose |
|---|---|
| `policies/*.rego` | The three control policies |
| `policies/*_test.rego` | The spec, provided by the challenge, unchanged |
| `evidence/opa-test.txt` | `opa test` output — `PASS: 6/6` |
| `evidence/plan-compliant.json` | Real week-1 plan; all three controls pass |
| `evidence/plan-broken.json` | Same plan with encryption removed; SC-28 fails |
| `evidence/conftest-gate.txt` | Captured Conftest run across both plans |

## Run it

```bash
# from 6week-challenge/week-2
opa test policies/ -v                                                         # 6/6
conftest test --policy policies --namespace compliance.sc28_aws evidence/plan-compliant.json
conftest test --policy policies --namespace compliance.sc28_aws evidence/plan-broken.json   # FAIL, by design
```

Requires `opa` and `conftest` (`brew install opa conftest`). Nothing is created in
AWS — `terraform plan` is read-only and both plans are committed as fixtures.

## The full writeup

[`SUBMISSION.md`](SUBMISSION.md) covers the technique that makes this work —
**matching by reference rather than by value**, because at plan time a bucket's final
name doesn't exist yet — plus why CM-6 detects taggability from `tags_all` instead of
hardcoding a resource list, and why AC-3 fails closed.

These policies are carried forward into [week 3](../week-3/), where they run as a CI
gate that blocks non-compliant pull requests.
