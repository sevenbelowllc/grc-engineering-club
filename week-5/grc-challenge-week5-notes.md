# Week 5: Turn On the Cameras

For four weeks you have been proving things about infrastructure you control. This week you turn on the native cloud controls that watch the account itself, capture what they see as evidence, sign it into the same chain you built last week, and tear it all down the same day. This is the one week that touches billable AWS services. **Read the cost section before you apply, follow it, and you will spend pennies.**

Two controls do the watching:

- **CloudTrail** records who did what in the account.
- **Security Hub** grades the account against a real NIST 800-53 baseline and hands you findings.

Both produce evidence a machine wrote, which is exactly the kind of evidence this pipeline collects.

> **Starter code:** grab `week-5-starter.zip` attached to this post. It ships a `teardown.sh` that captures findings then destroys, and a README. The Terraform is yours to write. That is the point: you have written Terraform for five weeks now, so standing up a trail and a standard is the rep that proves it stuck.

## What you are building

Two pieces, one apply.

### 1. A multi-region CloudTrail

It writes to a private, encrypted S3 bucket and runs with `enable_log_file_validation = true`. That last flag is the control. With validation on, CloudTrail emits a signed digest file every hour, so you can prove the log records have not been altered after the fact.

Control mapping:

| Control | Name | Why it applies |
|---------|------|----------------|
| AU-2 | Event logging | You chose what gets recorded |
| AU-12 | Audit record generation | Audit records generated across the account |
| AU-10 | Non-repudiation | The integrity of the audit info itself |

### 2. Security Hub with the NIST 800-53 Rev 5 standard

Enable the account, then subscribe the standard at:

```
arn:aws:securityhub:REGION::standards/nist-800-53/v/5.0.0
```

Security Hub runs a few hundred automated checks against that baseline and produces findings.

| Control | Name |
|---------|------|
| RA-5 | Vulnerability and configuration scanning |
| SI-4 | System monitoring |

### The bucket policy (read this twice)

The bucket policy is where people lose an hour. CloudTrail writes to your bucket as a service, and the bucket policy has to allow it. On current AWS that policy needs an `aws:SourceArn` condition scoped to your specific trail, not just the service principal. Without the condition, the trail either fails to create or refuses to write.

The Terraform registry page for `aws_cloudtrail` and the AWS docs for the CloudTrail bucket policy both show the exact statement. Read it, understand the condition, write your own.

### Skip AWS Config

It is genuinely optional here, and in most managed accounts an organization SCP blocks it anyway. There is a clean GRC lesson in that: Security Hub will raise a finding titled "AWS Config should be enabled," and that finding is itself valid evidence. A documented control gap, surfaced by an automated check, is exactly what you want your pipeline to capture. Do not fight the SCP. Let the gap show.

## Prerequisites

- An AWS account where you can create CloudTrail, S3, and Security Hub resources. A sandbox account is best.
- Terraform 1.6 or newer.
- AWS CLI v2 with a working profile. SSO users, export first:

  ```sh
  eval "$(aws configure export-credentials --profile <your-profile> --format env)"
  ```

- Your week 4 signing pipeline, so the findings file joins the chain of custody.
- About an hour, including the wait for findings.

## Cost

Read this and you will be fine.

- **CloudTrail management events are free.** One trail of management events costs nothing. Do *not* enable data events. Data events bill per event and are not part of this build. Leave them off.
- **Security Hub bills roughly $0.001 per check.** The NIST standard is a few hundred checks, so a full month is under about a dollar, and if you tear down within the hour it is pennies.
- **Apply and destroy the same day.** That keeps the whole week in pennies. Leaving it running adds up slowly, so do not leave it running. Tear it down.

## Build it

Open the starter and write the Terraform.

1. **The evidence bucket.** Private, encrypted, public access blocked on all four flags. You did exactly this in week 1, so reuse what you learned. This bucket holds CloudTrail logs, so it must exist before the trail.
2. **The bucket policy.** Allow the CloudTrail service principal to check the bucket ACL and to put objects, and scope both statements with the `aws:SourceArn` condition pointing at your trail's ARN. This is the snag. Get it right and the trail creates clean.
3. **The trail.** `aws_cloudtrail` with `is_multi_region_trail = true` and `enable_log_file_validation = true`, pointed at your bucket. The validation flag is the AU-10 control. Do not skip it.
4. **Security Hub.** Enable the account, then subscribe the NIST 800-53 Rev 5 standard by its ARN. Two resources.

## Capture the evidence

Security Hub needs time to run its checks. Wait 10 to 20 minutes after apply, then pull the findings.

Open the file. You should see real findings, very likely including "AWS Config should be enabled," each with a control ID, a severity, and a status. That JSON is your evidence for RA-5 and SI-4.

Now sign it. Run `evidence/security-hub-findings.json` through your week 4 pipeline so it gets a keyless signature and joins the chain of custody alongside your earlier bundles. This is the continuity that matters: native-control findings are now first-class evidence in the same signed chain as your plan and your gate output. Verify the signature the same way week 4 taught you, with `cosign verify-blob`, before you tear anything down.

## Done when

- [ ] `aws cloudtrail get-trail-status` shows `IsLogging: true`.
- [ ] `aws securityhub get-findings` returns at least one finding.
- [ ] `evidence/security-hub-findings.json` is captured and non-empty.
- [ ] The findings file carries a valid signature from your week 4 pipeline.
- [ ] `terraform destroy` completes and nothing is left billing.

## Tear it down

**This is not optional.** Run the starter's `teardown.sh`, which captures the findings first (in case you skipped that step) and then runs `terraform destroy`. If you destroy by hand, capture the findings file first, because once Security Hub is disabled the findings are gone.

Then confirm the account is clean. Check that the trail is gone and Security Hub is disabled, and empty and remove the evidence bucket if `destroy` left objects behind. Nothing should be billing when you walk away.

## On GCP?

The shape holds, the names change. Use organization policy constraints in place of account guardrails, turn on *Data Access audit logs* for the AU controls, and use *Security Command Center* in place of Security Hub for the RA-5 and SI-4 findings. Capture the SCC findings as JSON and sign them the same way. The control IDs do not move.

## Make it a portfolio piece

This entry shows you can stand up native controls, harvest their output as evidence, and shut the bill off cleanly. Hiring managers read that as operational maturity.

- The baseline Terraform in a public repo: the trail, the encrypted bucket with its `aws:SourceArn` policy, and the Security Hub standard.
- The captured `evidence/security-hub-findings.json`, with the signature alongside it.
- A README that names AU-2, AU-12, AU-10, RA-5, and SI-4, explains why log file validation matters, and notes that the "AWS Config should be enabled" finding is a documented gap, not a mistake.
- A one-line note that you tore it down the same day. Cost discipline is part of the skill.

Post on LinkedIn. Tag GRC Engineering Club, use **#GRCEngClubChallenge**, and share what the findings file surfaced that you did not expect.

## Common snags

| Snag | Fix |
|------|-----|
| CloudTrail will not create or write | The bucket policy is missing the `aws:SourceArn` condition scoped to your trail. Add it to both the ACL-check and put-object statements. |
| Security Hub is already enabled | Someone or something turned it on before you. Import it instead of fighting it: `terraform import aws_securityhub_account.this <ACCOUNT_ID>`, then apply. |
| Config access denied | That is your org SCP. Leave Config out, and let the Security Hub finding stand as evidence of the gap. |
| No findings yet | You checked too early. Wait the full 10 to 20 minutes and pull again. |

---

*Next week you stop building and start mapping: everything from all five weeks gets expressed in OSCAL against NIST 800-53, with evidence links pointing at your signed bundles, and you ship the portfolio case study that ties it together.*
