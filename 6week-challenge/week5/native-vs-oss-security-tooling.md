# AWS-Native vs. Open-Source Security Tooling

A practitioner's comparison of two stacks that cover the same three jobs —
**posture/compliance**, **vulnerability scanning**, and **threat / malware
detection** — plus a total-cost-of-ownership model.

| Job | AWS-native | Open-source / self-hosted |
|---|---|---|
| Config posture & compliance (CSPM) | **AWS Security Hub** | **Steampipe** (+ Powerpipe benchmarks) |
| Vulnerability scanning | **Amazon Inspector** | **Vuls** |
| Threat detection / file malware | **GuardDuty** | **ClamAV-on-Lambda** ("Clambda") |

> **Read the analogies as approximate.** The pairings line up by *job*, not
> feature-for-feature. Two mismatches matter and are called out below:
> GuardDuty is far broader than ClamAV (ClamAV only maps to GuardDuty's S3
> malware feature), and Steampipe is a query engine + benchmarks, broader in
> some ways and thinner in others than Security Hub.
>
> **Pricing is approximate**, region-dependent, and current as of early 2026 —
> verify against each vendor's pricing page before budgeting.

---

## 1. Posture & compliance — Security Hub vs. Steampipe

**What each does**

- **Security Hub (CSPM)** — subscribes managed standards (NIST 800-53, CIS,
  FSBP), evaluates your account against them *continuously* by reading **AWS
  Config**, and **aggregates** findings from Inspector, GuardDuty, Macie, etc.
  into one normalized view (ASFF).
- **Steampipe** — an open-source engine that queries live cloud/SaaS state with
  **SQL** via plugins. Layered with **Powerpipe** and the AWS Compliance mod, it
  runs the same benchmark families (CIS, NIST, PCI, SOC 2, FedRAMP) as
  **dashboards-as-code**, on demand or on a schedule you run.

| | Security Hub | Steampipe (+ Powerpipe) |
|---|---|---|
| Compliance benchmarks | Managed standards, auto-updated | Community mods (CIS/NIST/PCI/SOC2…), you update |
| Evaluation model | **Continuous** (change-triggered via Config) | **On-demand / scheduled** (you run it) |
| Data dependency | Requires **AWS Config** (hard dependency) | Queries live APIs directly — no Config needed |
| Aggregates other tools' findings | ✅ native (GuardDuty/Inspector/Macie) | ⚠️ only if you query them (there are plugins) |
| Multi-cloud / SaaS | ❌ AWS-only | ✅ 100+ plugins (AWS, Azure, GCP, GitHub, K8s…) |
| Ops | Fully managed | Self-hosted: run it, schedule it, store results |
| Output | Console + Security Hub findings | SQL results, dashboards, CSV/JSON you wire up |

**Where the analogy breaks:** Security Hub is also the **aggregation hub** for
the other two native tools — Steampipe is not an aggregator, it's a query
engine. Conversely, Steampipe's SQL-over-everything and **multi-cloud** reach is
something Security Hub simply doesn't do.

---

## 2. Vulnerability scanning — Inspector vs. Vuls

**What each does**

- **Amazon Inspector** — continuous, managed CVE scanning of **EC2, ECR images,
  and Lambda**. Inventory-based (SSM agent or agentless EBS snapshot), matches
  packages against vendor advisories (Ubuntu USN, ALAS, RHSA…), scores with
  network-reachability context, auto-rescans on new CVEs. Findings flow to
  Security Hub.
- **Vuls** — open-source **agentless** (SSH) Linux/host scanner. Uses distro
  OVAL / security-tracker data (`goval-dictionary`, `gost`, `go-cve-dictionary`)
  — also backport-aware. Scans servers, containers, libraries, network devices.

| | Amazon Inspector | Vuls |
|---|---|---|
| Targets | EC2, **ECR**, **Lambda** (AWS-native) | Linux/FreeBSD hosts, containers, libs, WordPress — **SSH to anything** |
| Backport-aware CVE matching | ✅ (USN/ALAS/RHSA) | ✅ (distro OVAL / security trackers) |
| Rescan model | **Continuous / auto on new CVE** | **Scheduled** (cron) |
| Network reachability context | ✅ | ❌ |
| ECR / Lambda native scanning | ✅ | ❌ (host/container focus) |
| Multi-cloud / on-prem | ❌ AWS-only | ✅ anywhere you can SSH |
| Ops | Managed, zero infra | Self-hosted: scanner host + CVE DBs + SSH keys + scheduling |
| Integration | Native → Security Hub | DIY (VulsRepo UI, Slack, S3, custom) |

**Verdict:** Inspector wins on zero-ops + AWS depth (ECR/Lambda/reachability);
Vuls wins on reach (on-prem, multi-cloud, non-AWS hosts) and $0 license.

---

## 3. Threat detection / file malware — GuardDuty vs. ClamAV-on-Lambda

**Important scope note:** ClamAV-on-Lambda only scans **uploaded files** for
malware. That maps to **one feature** of GuardDuty — **Malware Protection for
S3** — *not* to GuardDuty's core job. GuardDuty's threat detection (anomalous
API calls, crypto-mining, credential exfil, C2 traffic, from CloudTrail/VPC
Flow/DNS logs) has **no equivalent** in the OSS trio here.

| | GuardDuty | ClamAV-on-Lambda ("Clambda") |
|---|---|---|
| Account/network threat detection | ✅ (the core product) | ❌ none |
| S3 upload malware scanning | ✅ **Malware Protection for S3** | ✅ (this is all it does) |
| Detection engines | Multiple commercial | Single (ClamAV) |
| Max file size | ~5 GB/object | Lambda memory/timeout/`/tmp` limits (large files hard) |
| DB updates | Managed | **You run `freshclam`**; big DB → often needs EFS |
| Integration | Auto object-tag + EventBridge | DIY: S3 event → Lambda → tag/quarantine |
| Ops | Managed, standalone-enableable | You own the Lambda, layers, quarantine logic |

**Shared caveat (both):** neither blocks the upload synchronously — the object
lands, *then* is scanned, *then* you gate access on the result tag. Your read
path must **deny un-scanned/infected objects**, or "it's in the bucket" is
falsely read as "it's clean."

---

## 4. Cost comparison

Two different cost *shapes*: the native stack is **usage fees, near-zero ops**;
the OSS stack is **$0 license + infrastructure + engineering labor**. "Free"
describes the license, not the total cost.

### Native unit pricing (approximate)

| Service | Meter | ~Rate |
|---|---|---|
| Security Hub | per check | ~$0.0010; findings 10k/mo free |
| Inspector | EC2 / ECR / Lambda | ~$1.25/instance·mo · ~$0.09 image (init)/$0.01 rescan · ~$0.30/fn·mo |
| GuardDuty core | logs analyzed | CloudTrail ~$4.00/M events · VPC Flow+DNS ~$1.00/GB (tiered) |
| GuardDuty S3 malware | data scanned | ~$0.60/GB scanned + small per-object fee |

### Worked scenario

Reference environment: **40 Ubuntu EC2**, **25 Lambda**, **150 container images
(~600 scans/mo)**, **~5M CloudTrail mgmt events/mo + ~50 GB VPC Flow/DNS**, and
**~200 GB/100k objects of S3 uploads to malware-scan**.

**Native stack — monthly**

| Component | Calc | ~Monthly |
|---|---|---|
| Inspector | 40×$1.25 + ~600×$0.09 + 25×$0.30 | **~$110** |
| Security Hub | few hundred checks | **~$5** |
| GuardDuty core | 5M×$4/M + 50GB×$1 | **~$70** |
| GuardDuty S3 malware | 200GB×$0.60 (+objects) | **~$120** |
| **Total** | | **~$305/mo**, ~zero ops |

**OSS stack — monthly (TCO)**

| Component | Calc | ~Monthly |
|---|---|---|
| Steampipe host / CI | small runner | ~$15 |
| Vuls scanner + CVE DBs | small EC2 + storage | ~$40 |
| ClamAV Lambda + EFS | 200 GB compute + DB storage | ~$30 |
| **Hard infra subtotal** | | **~$85** |
| **Engineering labor** | ~6–15 hrs/mo × ~$100/hr loaded | **~$600–1,500** |
| **Total (TCO)** | | **~$685–1,585/mo** |
| *(plus one-time setup)* | ~40–100 hrs to stand up all three | *amortized* |

**Takeaway for a small-to-mid, AWS-only fleet:** the native stack is usually
**cheaper in total cost**, because the OSS license savings are swamped by the
engineering labor to run three tools — and you lose the native aggregation and
continuous-rescan automation.

### Where the OSS stack wins on cost

The break-even flips when:

- **Scale makes per-GB/per-resource fees explode.** GuardDuty S3 malware at
  **50 TB/mo** ≈ **$30,000/mo** — self-hosted ClamAV compute is dramatically
  cheaper at that volume. Same logic for very large EC2 fleets vs. Inspector's
  per-instance fee.
- **You need multi-cloud / on-prem / non-AWS coverage** — Steampipe and Vuls
  reach everywhere; the native tools are AWS-only, so you'd be buying a second
  toolset anyway.
- **You already have the security-engineering capacity** — the labor cost is
  already sunk, so the marginal cost of OSS is just infra.

---

## 5. Decision guide

| If you are… | Lean toward |
|---|---|
| Small team, AWS-only, want it working this week | **Native** (Security Hub + Inspector + GuardDuty) |
| Cost-sensitive at **large scale** (esp. high S3-malware GB or huge fleets) | **OSS** for the high-volume piece, native for the rest |
| **Multi-cloud / on-prem** | **OSS** (Steampipe + Vuls) — native can't reach non-AWS |
| Need **finding aggregation + continuous rescans** with minimal ops | **Native** — that's exactly what Security Hub + Inspector give you |
| Building a **portfolio / learning** the mechanisms | **OSS** — you see how CSPM, CVE matching, and AV actually work |

**The honest one-liner:** it's not "paid vs. free," it's **"buy managed usage"
vs. "buy engineer-hours to run open source."** The right answer flips on fleet
size, where your assets live, and what your engineering time is worth.

### A common real-world hybrid

Many teams run **both**: native tools for the AWS-runtime layer and effortless
Security Hub aggregation, and OSS (Steampipe for multi-cloud posture, Vuls/Trivy
in CI, ClamAV for high-volume upload scanning) where reach or per-GB cost makes
the managed option painful. The stacks aren't mutually exclusive — Steampipe can
even query Security Hub, GuardDuty, and Inspector findings via SQL.

---

*Pricing figures are approximate and change; treat them as a model, not a quote.
Confirm against current AWS and project documentation before budgeting.*
