# Week 5 — Turn On the Cameras

Stand up the native AWS controls that watch the *account itself*, capture what
they see as evidence, sign it into the week-4 chain of custody, and tear it all
down the same day. This is the one week that touches billable AWS services —
applied and destroyed within the hour, it costs pennies.

## What this builds (Terraform, `terraform/`)

| Piece | Purpose | Controls |
|---|---|---|
| **Multi-region CloudTrail** (home `us-west-2`), `enable_log_file_validation = true` | Records every API call across the account; hourly signed digests prove logs aren't altered after the fact | AU-2, AU-12, AU-10 |
| **Encrypted S3 log bucket** (`AES256`, all public access blocked, versioned) + `aws:SourceArn`-scoped bucket policy | Private, encrypted home for the trail | SC-28, AC-3 |
| **Cross-region replication** → a **us-east-2** replica bucket | Audit logs survive loss of the primary region — how real programs protect evidence | AU-9, CP-6, CP-9 |
| **Security Hub** + **NIST 800-53 Rev 5** standard | Grades the account against a real baseline and emits findings | RA-5, SI-4 |
| **AWS Config** recorder + delivery channel | The sensor layer Security Hub reads from — **required**, not optional (see below) | CA-7 |

## The gotcha this week taught: Security Hub needs AWS Config

At go-live, Security Hub returned **zero findings for ~45 minutes**. Every
standard sat `INCOMPLETE` with `NO_AVAILABLE_CONFIGURATION_RECORDER`. Security
Hub is a *reporting* layer — it reads the resource state that **AWS Config**
records. No Config recorder → no data → no findings. The challenge brief calls
Config optional; for a fresh account it is a hard dependency. `config.tf` adds
it. Once Config was recording, findings populated within ~30 minutes.

## Run it

```bash
cd terraform
terraform init && terraform apply          # review, type: yes  (billing starts)
# wait ~15-30 min for Security Hub to evaluate, then:
cd .. && ./capture-evidence.sh             # -> IsLogging true, findings >= 1, replica objects
./sign-evidence.sh                         # keyless cosign; one browser login
# verify (pin the identity you signed with):
EXPECT_ISSUER='<issuer>' EXPECT_IDENTITY='^<you>$' ../week-4/verify-evidence.sh evidence/week5-evidence.tar.gz
terraform -chdir=terraform destroy         # same day — billing stops
```

`force_destroy` on every bucket means `destroy` never stalls on log objects. A
Terraform `precondition` refuses to apply against any account other than the
intended sandbox.

## Verify it (trust nothing)

- **[`VERIFY-AND-EXPLORE.md`](VERIFY-AND-EXPLORE.md)** — a full independent
  verification runbook: CLI check + console path + "what good looks like" for
  every control, plus the signed-evidence tamper test.
- **[`cosign-keyless-signing-guide.md`](cosign-keyless-signing-guide.md)** — how
  the keyless signing + verification works, and how to pin the signer identity.

## Cost

Applied and destroyed the same day: **well under $1** (pennies). CloudTrail
management events are free; Security Hub bills ~$0.001/check; Config bills per
configuration item recorded. Left running, this small account is a few dollars a
month — which is why same-day teardown is the discipline, not an afterthought.

## Files

```
terraform/          buckets, CloudTrail, replication, Security Hub, AWS Config, outputs
capture-evidence.sh CloudTrail status + Security Hub findings + replica listing -> evidence/
sign-evidence.sh    bundle + sha256 + keyless cosign signature
teardown.sh         capture (safety) then terraform destroy
evidence/           captured + signed evidence (committed)
```

Verification reuses week-4's [`verify-evidence.sh`](../week-4/verify-evidence.sh)
— one chain of custody across both weeks.
