# Stretch: keyless plan generation with GitHub OIDC

The committed-`plan.json` path (the main deliverable) trusts a file a human
generated and checked in. The production version removes that trust: **CI reads
the cloud itself and generates the plan**, so the thing being gated is the real
intended state, not a snapshot someone remembered to refresh.

Doing that means CI needs cloud access. The wrong way is a stored `AWS_ACCESS_KEY`
secret — a long-lived credential sitting in repo settings that never expires and
leaks the same whether it's exfiltrated from a log or a fork. The right way is
**GitHub OIDC**: for each run, GitHub mints a short-lived signed token describing
*which repo, which workflow, which ref*, and AWS exchanges it for credentials
that live minutes and can't be replayed. Nothing is stored.

## Why keyless beats stored credentials

- **No standing secret.** There is no key to leak, rotate, or find in a git
  history. The credential exists only for the seconds a job runs.
- **Bound to identity, not possession.** Access is granted to *this repository's
  workflow*, proven cryptographically per run — not to anyone holding a string.
- **Scoped at the trust boundary.** The role's trust policy names the exact repo
  (`repo:sevenbelowllc/grc-engineering-club:*`). A stored key has no such
  binding; whoever has it, has it.
- **Least privilege.** The role is read-only. CI can describe state to build a
  plan; it can't change anything.

## Apply it (one time, your admin creds)

`iam-oidc.tf` is applied out of band — it is infrastructure *about* the pipeline,
not part of the week-1 build, and the gate never applies it.

```bash
cd 6week-challenge/week3/oidc
terraform init
terraform apply          # creates the OIDC provider + read-only grc-gate-oidc role
terraform output role_arn
```

If your account already has a
`token.actions.githubusercontent.com` OIDC provider, import it first
(`terraform import aws_iam_openid_connect_provider.github <arn>`) — AWS allows
only one provider per URL.

## Turn the CI job on

The `grc-gate-oidc` job is dormant until the repo variable exists, so merging
this workflow never breaks a repo that hasn't set AWS up:

```bash
gh variable set AWS_GATE_ROLE_ARN --body "<role_arn from the output above>"
gh variable set AWS_REGION        --body "us-east-1"   # optional; defaults to us-east-1
```

On the next PR, `grc-gate-oidc` assumes the role with no stored keys, runs
`terraform plan` / `show -json`, and gates the freshly generated plan with the
same three namespaces.

## The two things that actually matter

1. **Bind trust to the exact repo.** The `sub` condition is
   `repo:sevenbelowllc/grc-engineering-club:*`, never `repo:*:*`. A loose subject
   lets any repository on GitHub assume your role.
2. **Give the role only read access.** Plan generation describes state; it never
   writes. `ReadOnlyAccess` is the ceiling — tighten further to scoped
   `s3:Get*/List*` + `sts:GetCallerIdentity` if you want.
