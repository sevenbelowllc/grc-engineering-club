# Week 5 — Explore & Human-Verify Guide

How to independently confirm, by hand, that every claim in this week's work is
real: the controls are live, the evidence is genuine, and the signed chain of
custody holds. For each item you get a **CLI check** (fast, scriptable), a
**console path** (visual), and **what "good" looks like**.

Nothing here trusts the author — that's the point.

## 0. Setup

```bash
export AWS_PROFILE=default
export AWS_REGION=us-west-2
cd 6week-challenge/week5
```

Concrete resource names in this deployment (yours differ only by the random
suffix):

| Resource | Name |
|---|---|
| Account | `232929535631` |
| Trail | `grc-week5-dev-trail` |
| Log bucket (us-west-2) | `grc-week5-dev-ct-232929535631-ffd5f1b8` |
| Replica bucket (us-east-2) | `grc-week5-dev-ct-rep-232929535631-ffd5f1b8` |
| Config bucket (us-west-2) | `grc-week5-dev-config-232929535631-ffd5f1b8` |
| Config recorder | `grc-week5-dev-recorder` |
| NIST standard | `arn:aws:securityhub:us-west-2::standards/nist-800-53/v/5.0.0` |

Read the live output names directly with `terraform -chdir=terraform output`.

## 1. Right account?

```bash
aws sts get-caller-identity --query Account --output text     # -> 232929535631
```
**Console:** top-right account menu shows `…5631`.
**Good:** account is the intended sandbox, not prod.

---

## 2. CloudTrail — AU-2, AU-12, AU-10

```bash
aws cloudtrail describe-trails --region us-west-2 \
  --query "trailList[?Name=='grc-week5-dev-trail'].{multi:IsMultiRegionTrail,validation:LogFileValidationEnabled,bucket:S3BucketName,global:IncludeGlobalServiceEvents}"
aws cloudtrail get-trail-status --name grc-week5-dev-trail --region us-west-2 --query IsLogging
```
**Good:** `multi=true`, `validation=true`, `global=true`, `IsLogging=true`.

**Console:** CloudTrail → Trails → `grc-week5-dev-trail`. Confirm *Multi-region:
Yes*, *Log file validation: Enabled*, *Logging: On*. Open **Event history** and
watch your own API calls appear — that's AU-2/AU-12 in action.

**AU-10 deeper (log-file validation):** with validation on, CloudTrail writes a
signed **digest** file hourly. Once the account has been up ~1 hour:
```bash
aws cloudtrail validate-logs \
  --trail-arn arn:aws:cloudtrail:us-west-2:232929535631:trail/grc-week5-dev-trail \
  --start-time "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
```
**Good:** it reports log/digest files validated with no integrity errors. (If it
says no digests yet, the first hourly digest hasn't been written — that's timing,
not a failure.)

---

## 3. Log bucket — SC-28 (encryption), AC-3 (no public access)

```bash
B=grc-week5-dev-ct-232929535631-ffd5f1b8
aws s3api get-bucket-encryption      --bucket $B --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm'   # -> "AES256"
aws s3api get-public-access-block    --bucket $B --query 'PublicAccessBlockConfiguration'   # -> all four true
aws s3api get-bucket-versioning      --bucket $B --query Status                              # -> "Enabled"
aws s3api get-bucket-policy          --bucket $B --query Policy --output text | jq '.Statement[].Condition'
```
**Good:** AES256; all four public-access flags `true`; versioning `Enabled`; the
bucket policy's `aws:SourceArn` equals the trail ARN (the CloudTrail write scope).

**Console:** S3 → the bucket → **Properties** (Default encryption = SSE-S3) →
**Permissions** (Block public access = On for all four; Bucket policy shows the
`cloudtrail.amazonaws.com` grant with the SourceArn condition).

---

## 4. Cross-region replication — AU-9, CP-6 / CP-9

```bash
# The replication rule on the source bucket:
aws s3api get-bucket-replication --bucket grc-week5-dev-ct-232929535631-ffd5f1b8 \
  --query 'ReplicationConfiguration.Rules[0].{status:Status,dest:Destination.Bucket}'
# Objects that actually landed in the us-east-2 replica:
aws s3 ls s3://grc-week5-dev-ct-rep-232929535631-ffd5f1b8 --recursive --region us-east-2 | wc -l
```
**Good:** rule `status=Enabled`, destination = the us-east-2 replica ARN; the
replica object count is > 0 and climbs over time.

**Console:** S3 → source bucket → **Management → Replication rules** (one Enabled
rule → us-east-2). Then open the **replica bucket in us-east-2** and browse
`AWSLogs/…` — the same CloudTrail objects, now in a second region. That copy is
your audit-log survivability story.

**Prove it's a true copy:** pick one key from the replica listing and confirm it
also exists in the source bucket (`aws s3 ls s3://<source>/<key>`).

---

## 5. Security Hub — RA-5, SI-4

```bash
aws securityhub get-enabled-standards --region us-west-2 \
  --query "StandardsSubscriptions[?contains(StandardsArn,'nist-800-53')].StandardsArn"
aws securityhub get-findings --region us-west-2 --max-results 100 --query 'length(Findings)'   # >= 1
# See what the controls actually flagged:
aws securityhub get-findings --region us-west-2 --max-results 100 \
  --query 'Findings[].{sev:Severity.Label,status:Compliance.Status,title:Title}' --output table
```
**Good:** the NIST 800-53 v5 standard is subscribed; findings count ≥ 1; each
finding is a real control result (PASSED/FAILED) with a severity.

**Console:** Security Hub → **Security standards → NIST 800-53 Rev 5** → the
controls list with pass/fail per control. Open **Findings** for the full set.
Click `Config.1` (CRITICAL) to see the "use the service-linked role" detail and
its NIST CM-3 / CM-6(1) / CM-8 mappings shown right in the console.

---

## 6. AWS Config — CA-7 (and the reason Security Hub works)

```bash
aws configservice describe-configuration-recorder-status --region us-west-2 \
  --query 'ConfigurationRecordersStatus[0].{recording:recording,lastStatus:lastStatus,err:lastErrorMessage}'
aws configservice describe-configuration-recorders --region us-west-2 \
  --query 'ConfigurationRecorders[0].recordingGroup'
```
**Good:** `recording=true`, `lastStatus=SUCCESS` (or `PENDING` right after
start), no error; recording group `allSupported=true`,
`includeGlobalResourceTypes=true`.

**Console:** Config → **Settings** (Recording = On, delivery to the Config
bucket) → **Resource inventory** (the resources Config has discovered — this is
the data Security Hub reads). This is why turning Config off yields zero
findings: no inventory, nothing to evaluate.

---

## 7. The captured evidence files

```bash
ls -la evidence/
jq '.Findings | length' evidence/security-hub-findings.json        # 12 at capture time
jq '{IsLogging}' evidence/cloudtrail-status.json                    # true
wc -l evidence/replica-listing.txt                                 # 53 replicated objects
```
**Good:** three non-empty evidence files matching what the live account reports.

**Cross-check they're real (not fabricated):** re-pull live and compare titles.
```bash
diff \
  <(jq -r '.Findings[].Title' evidence/security-hub-findings.json | sort) \
  <(aws securityhub get-findings --region us-west-2 --max-results 100 --query 'Findings[].Title' --output text | tr '\t' '\n' | sort)
```
Overlap confirms the committed evidence came from this account (exact match only
while the stack is still up and unchanged).

---

## 8. The signed chain of custody — the crux

This is the "verify without trusting the author" step.

**8a. Integrity (did the bytes change?)**
```bash
shasum -a 256 evidence/week5-evidence.tar.gz
cat evidence/week5-evidence.tar.gz.sha256
```
**Good:** the two hashes are identical.

**8b. Who signed it? (read the cert, don't take my word)**
```bash
# Deliberately-wrong values make cosign print the real subject + issuer:
cosign verify-blob --bundle evidence/week5-evidence.tar.gz.sig.bundle \
  --certificate-identity 'x' --certificate-oidc-issuer 'x' \
  evidence/week5-evidence.tar.gz 2>&1 | grep -i 'got'
```
**Good:** `got subject … dkramer@sevenbelow.com … issuer https://accounts.google.com`.

**8c. Full verification (integrity + authenticity + transparency log)**
```bash
EXPECT_ISSUER='https://accounts.google.com' \
EXPECT_IDENTITY='^dkramer@sevenbelow\.com$' \
  ../week4/verify-evidence.sh evidence/week5-evidence.tar.gz
```
**Good:** `integrity: OK` → `authenticity: OK` → `CHAIN INTACT`. `cosign` also
confirms the signature is recorded in Sigstore's public **Rekor** transparency
log — so the signing event is independently auditable, not just a local claim.

**8d. Tamper test (one byte breaks it)**
```bash
cp evidence/week5-evidence.tar.gz{,.sha256,.sig.bundle} /tmp/ 2>/dev/null; \
cp evidence/week5-evidence.tar.gz /tmp/t.tar.gz; \
cp evidence/week5-evidence.tar.gz.sha256 /tmp/t.tar.gz.sha256; \
cp evidence/week5-evidence.tar.gz.sig.bundle /tmp/t.tar.gz.sig.bundle; \
echo junk >> /tmp/t.tar.gz
EXPECT_ISSUER='https://accounts.google.com' EXPECT_IDENTITY='^dkramer@sevenbelow\.com$' \
  ../week4/verify-evidence.sh /tmp/t.tar.gz; echo "exit=$?"
rm -f /tmp/t.tar.gz*
```
**Good:** `FAIL: integrity: sha256 mismatch`, `exit=1`. Custody is mathematical,
not a promise.

---

## 9. Control-to-check map

Every control this week claims, and the section above that proves it:

| Control | Proven by |
|---|---|
| AU-2 / AU-12 (event logging, record generation) | §2 — trail logging, Event history |
| AU-10 (non-repudiation) | §2 — log-file validation + `validate-logs` |
| AU-9 / CP-6 / CP-9 (protect audit info / alternate site) | §4 — replica bucket populated |
| RA-5 / SI-4 (vuln-config scan / monitoring) | §5 — Security Hub NIST findings |
| CA-7 (continuous monitoring) | §6 — Config recorder feeding Security Hub |
| SC-28 (encryption at rest) | §3 — AES256 on the buckets |
| AC-3 (access enforcement) | §3 — public access blocked |
| Chain of custody (integrity/authenticity/timeliness) | §8 — `CHAIN INTACT` + tamper test |

---

## 10. When you're done exploring

Stop the billing the same day:
```bash
terraform -chdir=terraform destroy   # review, then: yes
# Confirm nothing remains:
aws cloudtrail describe-trails --region us-west-2 --query "trailList[?Name=='grc-week5-dev-trail']"   # -> []
aws securityhub describe-hub --region us-west-2   # -> not subscribed
aws configservice describe-configuration-recorders --region us-west-2   # -> empty
```
**Good:** empty trail list, Security Hub not subscribed, no recorder — nothing
left billing. The **committed evidence** (§7, §8) remains fully verifiable
forever, even though the live stack is gone. That permanence is the whole point:
the proof lives in the signed bundle and the public transparency log, not in the
running infrastructure.
