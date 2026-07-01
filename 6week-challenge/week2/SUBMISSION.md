# Week 2 Submission — Make the Rules Executable

## Writeup

Week 1 built a compliant bucket. "Compliant" was still a *claim* — something a
human had to read a plan and vouch for. Week 2 replaces the human with code: three
[Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) policies that
read a Terraform plan (`terraform show -json`) and return a verdict on each NIST
800-53 control the same way every time, in milliseconds.

Three controls, one policy each, each a `deny` rule that emits a message naming the
offending resource and the remediation:

- **SC-28 — Protection of Information at Rest.** Deny any `aws_s3_bucket` with no
  matching `aws_s3_bucket_server_side_encryption_configuration`.
- **AC-3 — Access Enforcement.** Deny any `aws_s3_bucket` whose
  `aws_s3_bucket_public_access_block` is missing, or has any of its four flags
  (`block_public_acls`, `block_public_policy`, `ignore_public_acls`,
  `restrict_public_buckets`) not set to `true`.
- **CM-6 — Configuration Settings.** Deny any *taggable* resource missing one of the
  four required tags (`Project`, `Environment`, `ManagedBy`, `ComplianceScope`).

All six unit tests pass, and the same policies gate the real Week 1 plan.

## The one technique: match by reference, not by value

At plan time a bucket's final name is unknown — the `random_id` suffix hasn't been
generated yet — so you **cannot** join an encryption resource to its bucket by
comparing names. You join by **reference**.

Terraform's plan JSON has two halves that matter:

- `configuration.root_module.resources[]` — what you *declared*, including the static
  references between resources. The encryption resource records its bucket link as
  `expressions.bucket.references = ["aws_s3_bucket.primary.id", "aws_s3_bucket.primary"]`.
- `planned_values.root_module.resources[]` — the concrete values Terraform intends to
  set (the four public-access flags, the tag maps).

So SC-28 and AC-3 build each bucket's declared address (`aws_s3_bucket.<name>`) and
ask: does some sibling resource carry a `references` entry that resolves to that
address? The match helper accepts the bare address or any attribute of it:

```rego
references_bucket(ref, bucket_addr) if ref == bucket_addr
references_bucket(ref, bucket_addr) if startswith(ref, sprintf("%s.", [bucket_addr]))
```

AC-3 then crosses from `configuration` to `planned_values` by the block's `address`
to read the actual flag values. CM-6 needs no reference trick at all — tags are plain
values in `planned_values`.

## Two design decisions worth explaining

**CM-6 "taggable" is detected, not hardcoded.** A real plan contains the encryption
config, the public-access block, ACL, and logging resources — none of which are
taggable in AWS. If CM-6 flagged every resource lacking tags, the *compliant* Week 1
plan would fail. The rule instead treats a resource as taggable only if the plan emits
a `tags_all` (preferred) or `tags` map for it:

```rego
effective_tags(r) := r.values.tags_all if is_object(r.values.tags_all)
effective_tags(r) := r.values.tags     if { not is_object(r.values.tags_all); is_object(r.values.tags) }
```

The AWS provider models `tags_all` as a *computed* schema attribute on exactly the
taggable resource types, so its presence is an authoritative, self-maintaining signal —
no 500-entry resource-type list to drift, and no hardcoding of one cloud. Because it's
computed, provider `default_tags` populate it even when a resource declares no `tags`
block, so an untagged-but-taggable resource still surfaces (as an empty or partial map)
and is caught rather than silently skipped.

**AC-3 fails closed.** A bucket is compliant only if a matching block exists *and* all
four flags read `true`. Missing block, unmatched in `planned_values`, or any flag not
`true` → denied. The safe default for a control gate is to deny when it cannot prove
compliance.

**Nested modules are handled.** Both config- and planned-side resource collection use
`walk` to gather every array whose path ends in `resources`, so `root_module.resources`,
`child_modules[...].resources`, and `module_calls[...].module.resources` are all covered —
a module-wrapped bucket is never silently missed.

## Proof

### Unit tests — the spec, six green

```
$ opa test policies/ -v
```

See [`evidence/opa-test.txt`](evidence/opa-test.txt) — `PASS: 6/6`.

### Real infrastructure — the actual gate

Unit tests use tiny fixtures. The real test is the Week 1 plan. Both plans below were
produced with `terraform show -json` from a fresh copy of the Week 1 workspace (two
buckets: `primary` + `log`) and are committed as evidence.

```bash
# Compliant Week 1 plan — all three controls pass
conftest test --policy policies --namespace compliance.sc28_aws evidence/plan-compliant.json
conftest test --policy policies --namespace compliance.ac3_aws  evidence/plan-compliant.json
conftest test --policy policies --namespace compliance.cm6_aws  evidence/plan-compliant.json
```

Then prove the gate actually catches something — a copy of the workspace with the
encryption blocks deleted:

```bash
conftest test --policy policies --namespace compliance.sc28_aws evidence/plan-broken.json
# FAIL - SC-28: aws_s3_bucket 'primary' has no matching server-side encryption configuration. Remediation: ...
# FAIL - SC-28: aws_s3_bucket 'log' has no matching server-side encryption configuration. Remediation: ...
```

SC-28 fails and names **both** buckets with the fix, while AC-3 and CM-6 stay green —
the gate isolates the one control that broke. Full captured output:
[`evidence/conftest-gate.txt`](evidence/conftest-gate.txt).

## What this repo contains

| Path | Purpose |
|---|---|
| `policies/*.rego` | The three control policies (SC-28, AC-3, CM-6) |
| `policies/*_test.rego` | The spec — provided by the challenge, unchanged |
| `evidence/opa-test.txt` | `opa test` output, 6/6 passing |
| `evidence/plan-compliant.json` | Real Week 1 plan — all three controls pass |
| `evidence/plan-broken.json` | Same plan, encryption removed — SC-28 fails |
| `evidence/conftest-gate.txt` | Captured Conftest run against both plans |

## Run it yourself

```bash
# from 6week-challenge/week2
opa test policies/ -v                                                          # 6/6
conftest test --policy policies --namespace compliance.sc28_aws evidence/plan-compliant.json
conftest test --policy policies --namespace compliance.sc28_aws evidence/plan-broken.json   # FAIL, by design
```

Requires `opa` and `conftest` (`brew install opa conftest`). Everything runs on a
laptop; no AWS resources are created (`terraform plan` is read-only).

## Portability

OPA doesn't care about the cloud — the policies do, in exactly one place each: the
resource-type strings. A GCP build would match `google_storage_bucket` and read
`labels` instead of `tags`; the control IDs (SC-28, AC-3, CM-6) stay identical. That's
the point — a control is portable, a rule that hardcodes one cloud's resource type is
not.
