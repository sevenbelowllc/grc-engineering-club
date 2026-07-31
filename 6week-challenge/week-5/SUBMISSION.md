# Week 5 Submission — Turn On the Cameras

## Writeup

For four weeks I proved things about infrastructure I built. This week I turned
on the native AWS controls that watch the *account itself*, captured what they
saw, and signed it into the same chain of custody from week 4 — then tore it all
down the same day for pennies.

Two cameras do the watching:

- **CloudTrail** — a multi-region trail (home `us-west-2`), with
  `enable_log_file_validation = true`, writing to a private, `AES256` S3 bucket.
  It records who did what across the account. Log-file validation is the control
  that matters: CloudTrail emits a signed digest every hour, so tampering with a
  past log record is detectable. That's non-repudiation (AU-10), not just logging.
- **Security Hub** — with the **NIST 800-53 Rev 5** standard subscribed. It runs
  a few hundred automated checks against a real baseline and hands back findings.
  Machine-written evidence for RA-5 and SI-4.

Both produce evidence a machine wrote, which is exactly what a chain-of-custody
pipeline is supposed to collect.

## The lesson: a dashboard is only as good as its sensor

I applied the stack, waited, and Security Hub gave me **zero findings. For 45
minutes.** Not "still populating" — genuinely zero, and it would have stayed
zero forever. Every standard sat `INCOMPLETE`, reason:
`NO_AVAILABLE_CONFIGURATION_RECORDER`.

Here's the nuance, and it's the whole point of the week:

→ **Security Hub is a reporting layer, not a sensor.** It doesn't inspect your
resources directly. It reads the resource state that **AWS Config** records.

→ **No Config recorder means no data to grade.** The checks can't run, so nothing
is produced — not even the "AWS Config should be enabled" finding.

The challenge brief called Config optional. For a fresh account it is a **hard
dependency**. The honest version of "I enabled continuous monitoring" isn't
"I turned on Security Hub" — it's "I turned on the *sensor* (Config) and the
*grader* (Security Hub), and confirmed the grader was actually receiving data."
I added `config.tf` (recorder + delivery channel + encrypted bucket + IAM role),
and findings populated within ~30 minutes.

## The secondary region, because that's how it works for real

Audit logs are the one thing you must be able to trust *after* an incident. If
they live in exactly one region and one bucket, a regional failure — or someone
with write access to that bucket — can take out your evidence. So I replicated
the CloudTrail log bucket **cross-region to us-east-2**.

→ Same-region only protects against *nothing* that matters when the region
itself is the problem.

→ Cross-region replication means the evidence survives the loss of the primary.
That's AU-9 (protection of audit information) and the CP-6/CP-9 alternate-site
story.

At capture time, **53 CloudTrail objects had already replicated** to us-east-2 —
the copy is real, not theoretical. (The production gold standard is a separate
*account*, not just a separate region, so even an account-level admin can't reach
the copy. That needs AWS Organizations, out of scope for a single-account
sandbox — but the region story is the honest single-account version of it.)

## Chain of custody: the findings join the week-4 signature chain

Capturing evidence isn't enough if an auditor has to *take on faith* that the
`security-hub-findings.json` in the repo is the real one. So the findings run
through the exact keyless-cosign pipeline from week 4: bundle → SHA-256 →
`cosign sign-blob`. Signed locally, keyless — Sigstore's CA issues a short-lived
certificate bound to my verified identity and records it in a public
transparency log. No private key to store or leak.

```
$ EXPECT_ISSUER='https://accounts.google.com' \
  EXPECT_IDENTITY='^dkramer@sevenbelow\.com$' \
  ../week-4/verify-evidence.sh evidence/week5-evidence.tar.gz
integrity:    OK  (b7b4ef92ab9b9172efa6a3715a42afa90e0b4299942891e94f12c6fce16699b5)
authenticity: OK  (issuer=https://accounts.google.com)
CHAIN INTACT
```

Append a single byte to the bundle and it fails immediately on integrity, before
the signature is even checked — `FAIL: integrity: sha256 mismatch`, exit 1.
Native-control findings are now first-class evidence in the same signed chain as
my Terraform plan and my policy-gate output.

## The most interesting finding: Config.1 flagged my own Config

Of the 12 findings captured, the one CRITICAL is `Config.1` — *"AWS Config should
be enabled and use the service-linked role for resource recording."* I **did**
enable Config; I used a **custom IAM role** with equivalent permissions, and the
control specifically wants the AWS *service-linked* role, so it flags me.

That's not a bug to hide — it's the pipeline working. An automated control caught
that my setup deviates from the recommended pattern. The correct GRC response
isn't to silently "fix" it; it's a **documented deviation**: custom role,
equivalent permissions, switching to the service-linked role would clear it. A
documented, understood finding is stronger evidence than a suspiciously all-green
dashboard. (It maps to NIST CM-3, CM-6(1), CM-8, CM-8(2).)

## Evidence index

| Artifact | What it proves |
|---|---|
| [`evidence/cloudtrail-status.json`](evidence/cloudtrail-status.json) | `IsLogging: true` — the trail is recording (AU-2/AU-12) |
| [`evidence/security-hub-findings.json`](evidence/security-hub-findings.json) | 12 NIST/CIS findings — machine-written RA-5/SI-4 evidence |
| [`evidence/replica-listing.txt`](evidence/replica-listing.txt) | 53 CloudTrail objects replicated to us-east-2 (AU-9) |
| [`evidence/week5-evidence.tar.gz`](evidence/week5-evidence.tar.gz) | The signed bundle of all three |
| [`evidence/week5-evidence.tar.gz.sha256`](evidence/week5-evidence.tar.gz.sha256) | Integrity — the hash the tamper test breaks |
| [`evidence/week5-evidence.tar.gz.sig.bundle`](evidence/week5-evidence.tar.gz.sig.bundle) | Authenticity — keyless cert + signature + Rekor entry |
| [`terraform/`](terraform/) | The whole stack as code: trail, buckets, replication, Security Hub, Config |
| [`VERIFY-AND-EXPLORE.md`](VERIFY-AND-EXPLORE.md) | Independent verification runbook — CLI + console per control |

## Control mapping

| Control | Name | Implemented by |
|---|---|---|
| AU-2 / AU-12 | Event logging / audit record generation | CloudTrail records the account |
| AU-10 | Non-repudiation | `enable_log_file_validation` (hourly signed digests) |
| AU-9 | Protection of audit information | Cross-region replication of the log bucket |
| CP-6 / CP-9 | Alternate storage site / backup | us-east-2 replica of audit logs |
| RA-5 / SI-4 | Vulnerability scanning / system monitoring | Security Hub NIST 800-53 findings |
| CA-7 | Continuous monitoring | AWS Config recorder feeding Security Hub |
| SC-28 | Protection at rest | `AES256` on all buckets |
| AC-3 | Access enforcement | All four public-access-block flags on every bucket |

## Done when — checklist

- [x] Multi-region CloudTrail with log-file validation, writing to an encrypted bucket with a correct `aws:SourceArn` policy
- [x] `get-trail-status` shows `IsLogging: true`
- [x] Security Hub enabled with the NIST 800-53 Rev 5 standard subscribed
- [x] AWS Config enabled — the dependency that makes findings possible
- [x] `get-findings` returns ≥ 1 finding; `security-hub-findings.json` captured, non-empty (12 findings)
- [x] Audit logs replicated cross-region to us-east-2 (AU-9), 53 objects at capture
- [x] Findings signed into the week-4 cosign chain — `CHAIN INTACT`; tamper test fails on integrity
- [x] `terraform destroy` completes — nothing left billing
- [x] Post to LinkedIn, tagging GRC Engineering Club with `#GRCEngClubChallenge`
