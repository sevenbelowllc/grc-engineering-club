# WORM vs. a "Cannot-Delete" Permission: What Immutable Evidence Really Means

*A GRC-engineering deep dive on S3 Object Lock, chain-of-custody preservation, and
the precise, defensible claim you can make to an auditor.*

> Origin: this note captures a working discussion that started from a single
> Terraform file — the immutable "evidence vault" in Week 4 of the GRC
> Engineering Club 6-week challenge — and turned into a careful pull-apart of
> what "immutable" actually guarantees. Every AWS behavioral claim below is
> grounded in AWS documentation (sources at the end); the one conditional caveat
> (KMS crypto-shredding) is labelled as such.

---

## 1. Where this started: the purpose of `vault.tf`

Week 4 of the challenge is about **chain of custody** for pipeline evidence:
after the CI gate produces evidence, we sign it (Cosign, keyless) so anyone can
prove it is authentic and untampered without trusting us. Chain of custody, in
plain terms, answers four questions, each mapped to a concrete artifact:

| Property | Question | Answered by |
| --- | --- | --- |
| **Integrity** | Has it changed since? | SHA-256 hash |
| **Authenticity** | Who produced it? | Keyless signature (cert bound to repo + workflow) |
| **Timeliness** | When was it produced? | Signed timestamp + transparency-log entry |
| **Preservation** | Can it still be retrieved, unaltered? | Immutable storage — the vault |

`vault.tf` is the **preservation** leg. It defines an AWS S3 bucket engineered so
that once a signed evidence bundle lands in it, it cannot be overwritten or
deleted — even by the account owner — until a retention window expires. The key
settings:

- `object_lock_enabled = true` on the bucket (simplest to set at creation; since
  Nov 2023 AWS also supports enabling Object Lock on *existing* versioned buckets
  — see §8);
- versioning **Enabled** (Object Lock requires it);
- an Object Lock configuration with **`mode = "COMPLIANCE"`** and a retention
  period;
- a full public-access block;
- a least-privilege bucket policy granting exactly one action — `s3:PutObject` —
  to exactly one principal (the pipeline role). Nothing can read-all, delete, or
  wildcard.

In this repository the vault ships **dormant**: it is validated Terraform, not
applied anywhere, gated behind a repo variable so it never runs in CI until you
opt in. So today the *live* chain of custody rests on the hash and the signature;
preservation is the documented "here's how you close the last gap" stretch.

### Two honest naming/scope caveats

- **"Vault" is an overloaded word.** In infrastructure circles it most often
  means **HashiCorp Vault**, a secrets manager — a completely different product.
  Naming an S3 Object Lock bucket module `vault` is evocative but can mislead; a
  clearer name would be `evidence-store/` or `worm-bucket/`.
- **The layout is a local convention, not a standard.** A module-per-concern
  subdirectory is normal Terraform hygiene, but the conventional file split is
  `main.tf` / `variables.tf` / `outputs.tf`, not a single file named after the
  resource. Fine for a small dormant stretch; just not a mandated structure.

---

## 2. Is an immutable evidence store a "real" GRC pattern?

Yes. Keeping audit evidence in tamper-proof, **WORM** (write-once-read-many)
storage so it cannot be altered or deleted after the fact is a well-established
compliance control, not something invented for a challenge:

- **NIST 800-53** — AU-9 (*Protection of Audit Information*) and AU-11 (*Audit
  Record Retention*): protect logs/evidence from unauthorized modification or
  deletion and retain them for a defined period. Object Lock in COMPLIANCE mode
  is a textbook implementation.
- **Records-retention regimes** — SEC Rule 17a-4(f), FINRA Rule 4511(c), CFTC
  Rule 1.31(c) explicitly require non-rewritable, non-erasable (WORM) storage.
  AWS commissioned an independent assessment from **Cohasset Associates** (a
  records-management compliance firm) concluding that S3 Object Lock meets those
  WORM requirements when retention is applied.
- Conceptually it's the "immutable audit trail / evidence locker" pattern that
  recurs across GRC tooling. Azure Immutable Blob and GCP Bucket Lock are the
  cloud equivalents.

So the *control* the vault implements is standard and recognized. The *name* is
just our label for it.

---

## 3. The core distinction: WORM is not a "cannot-delete" permission

The heart of the discussion. A "deny delete" IAM permission and Object Lock WORM
look similar from the outside but are fundamentally different kinds of control:

| | IAM "deny delete" permission | Object Lock (COMPLIANCE) WORM |
| --- | --- | --- |
| **What it is** | An *access rule* attached to an identity/policy | A *property of the object version itself* — a retention timestamp stored with the data |
| **Enforced against** | Whoever makes the request (identity-based) | Everyone, unconditionally — including the account root |
| **Can it be removed?** | Yes — anyone with admin/`iam:*` can edit or delete the policy | No — in COMPLIANCE mode nobody can delete it, shorten it, or bypass it until the retention date passes |
| **Scope** | Usually just "delete" | Blocks delete **and** overwrite/modify of the locked version |
| **Enforcement layer** | Evaluated at request time by IAM | Enforced by the S3 data plane on the object itself |

Three reasons the "it's just a can't-delete permission" framing breaks:

1. **A permission can be lifted; WORM cannot (within its window).** A deny-delete
   policy is only as strong as the policy staying in place. An admin — or an
   attacker who compromises admin/root credentials — can edit the policy off and
   then delete the object. COMPLIANCE-mode Object Lock has no such override path.
   This matters because the actor you are most worried about (the privileged
   insider, or a compromised root credential) is exactly the actor who can remove
   permissions. A permission-based control does not defend against them; WORM
   does.
2. **WORM is also "write once," not just "don't delete."** It prevents
   overwriting the existing bytes, not only deletion.
3. **Different layer, different threat model.** A permission is an IAM decision
   about a caller; Object Lock is a storage-level property of the data enforced
   regardless of who asks.

The one place the "permission" intuition *is* accurate: **GOVERNANCE mode**.
Object Lock in Governance mode can be overridden by a caller holding
`s3:BypassGovernanceRetention` (which includes root by default), so it behaves
like a strong, privilege-gated restriction — closer to a permission. That is
precisely why the vault uses **COMPLIANCE** mode, not Governance: for evidence
preservation you want the tier that *cannot* be reduced to a permission someone
can wield.

---

## 4. The correction that sharpened everything: immutable ≠ eternal

An important precision emerged. Saying "a permission can be lifted; WORM cannot"
can be misread as "a WORM object can never be deleted, ever." That is **not**
what WORM means.

**WORM is time-bounded immutability.** The object is locked *until a specific
retention date*. During that window it is immutable to everyone. After that date
passes, it becomes an ordinary object again and can be deleted by anyone with
normal delete permission. So the honest statement is:

> A COMPLIANCE-mode WORM object cannot be lifted or deleted **during the retention
> window**. It is not "un-deletable forever" — it is un-deletable *until the date*.

Collapsing "can't be bypassed" and "can't ever be deleted" into one phrase is the
common imprecision. They are different claims, and the time-bound is load-bearing.

---

## 5. Can the AWS root user change, modify, or delete a WORM object?

The direct question, answered precisely for **COMPLIANCE mode, during the
retention window**:

**No. Root is not special here.** Object Lock in Compliance mode is enforced
against every principal — including the account root and AWS itself. During
retention, root **cannot**:

- delete the locked object **version**;
- overwrite or modify its bytes (S3 objects are immutable anyway — a "modify" is
  really a *new* version; the locked version stays and remains retrievable);
- shorten the retention date;
- switch the object from COMPLIANCE to GOVERNANCE mode;
- disable Object Lock or remove the retention.

The only change root **can** make to the lock is to **extend** it. Retention is a
one-way ratchet — up, never down.

### The nuance that looks like deletion but isn't

In a versioned bucket, root can issue a "delete" *without a version ID*. That
drops a **delete marker** on top, so a plain `GET` now returns "not found." But
the underlying locked version still exists and is fully retrievable by its
version ID, and the delete marker itself can be removed. That operation **hides**
the object; it does not **destroy** the data. The bytes are still there, still
locked.

---

## 6. The residual escape hatches (outside Object Lock's scope)

"Root can't touch it" is true at the object level, for the window — but honesty
requires naming the ways the data can still disappear. None of these "delete the
WORM object"; they operate at a level Object Lock does not govern.

### 6a. Closing the entire AWS account

This is the documented escape hatch — and, for actually removing a locked object
before expiry, **the only one.** Per AWS documentation, *the only way to delete an
object under Compliance mode before its retention date expires is to close the
associated AWS account.* There is **no bypass permission** in Compliance mode
(unlike Governance's `s3:BypassGovernanceRetention`), and root is not exempt.

Note what this is and isn't: closing the account does not *bypass* the lock — it
**destroys the container around it.** The lock is never defeated; you terminate
the entire account, wait out the ~90-day recoverable grace period, and everything
is purged together (see §7). The delete-marker trick (§5) and crypto-shredding
(§6b) are likewise not overrides — one hides, the other destroys readability.
So the precise statement is: **the lock itself has no pre-expiry override; the
sole exit is destroying the account that holds it.**

### 6b. Crypto-shredding — *only if you opted into customer-managed KMS*

If objects are encrypted with a **customer-managed KMS key (SSE-KMS)**, a
privileged user could schedule that key for deletion (a mandatory waiting period
applies, configurable 7–30 days) or disable it. The ciphertext object stays
locked and undeleted, but becomes cryptographically **unreadable** — effectively
destroyed without touching Object Lock.

**This is not a risk for the vault as written**, because `vault.tf` does not
configure SSE-KMS; S3 defaults to SSE-S3 (AES-256) with an AWS-managed key that
cannot be deleted. It is the honest caveat to raise if someone "hardens" the
vault with a customer KMS key — they would be adding a deletion vector that
bypasses WORM.

---

## 7. Does an unexpired retention date hold up account deletion?

The specific follow-up: if root closes the account, does a remaining WORM
retention **block or delay** the account's deletion? **No. The two are
independent, and Object Lock does not govern account closure.** Verified against
AWS documentation:

- **Closure proceeds normally.** A remaining COMPLIANCE retention does not block
  the close, extend the timeline, or force AWS to wait until the retention date
  passes. The lock protects objects *within* a live account; it does not reach up
  to protect the account from being closed.
- **A standard ~90-day grace period applies — the same for everyone, regardless
  of retention length.** The account sits suspended and recoverable for ~90 days
  (you can reopen it in that window). A 7-year retention does **not** stretch that
  to 7 years; it is still ~90 days.
- **After the grace period, AWS permanently deletes all account resources —
  including compliance-locked objects — regardless of remaining retention.** A
  locked object with years left is purged along with everything else once the
  account is gone.

So the deletion timeline is driven entirely by the **account-closure lifecycle**,
not by the object's retention date. Retention governs deletion *inside* a
functioning account; account closure is a level above it that Object Lock simply
does not reach.

---

## 8. Configuring Compliance mode — and why the lock is "greater than a delete"

A useful reframing surfaced in the discussion: **a Compliance lock is, in a real
sense, stronger than deletion.** A delete is just an API capability that any
principal holding the permission can exercise. A Compliance lock *removes that
capability from everyone* — including root — for the retention window. Deletion
is not merely restricted; it is **not an available operation** on that object
version. That is why "locked" outranks "delete" here.

### The mechanics that create the guarantee

1. **Enable versioning** — Object Lock requires it (retention is per *version*).
2. **Enable Object Lock on the bucket.** Setting it at creation is cleanest;
   since **2023-11-20** AWS also supports enabling it on *existing* versioned
   buckets via `PutObjectLockConfiguration`. (This corrects the older
   "creation-only" belief.)
3. **Apply a retention rule in `COMPLIANCE` mode.** Two ways:
   - **Bucket default retention** — every new object is auto-locked, so no write
     slips in unprotected. This is what *ensures* coverage:
     ```bash
     aws s3api put-object-lock-configuration --bucket my-vault \
       --object-lock-configuration '{"ObjectLockEnabled":"Enabled",
         "Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Years":7}}}'
     ```
   - **Per-object retention** — set `--object-lock-mode COMPLIANCE
     --object-lock-retain-until-date <ISO8601>` on `PutObject`, or via
     `PutObjectRetention`.
4. Once set, S3 enforces at the data-plane level for **all** principals: no one
   can delete the version, shorten the date, downgrade COMPLIANCE→GOVERNANCE, or
   disable Object Lock; retention is **extend-only**; and the bucket cannot be
   deleted while locked objects remain.

### Closing the one escape hatch: deny account closure

Object-level Compliance mode is airtight, but "ensure" is not complete until you
address the sole residual exit — closing the account (§6a, §7). You harden that
at the **AWS Organizations** layer:

- Attach a root/OU **service control policy (SCP) that denies
  `account:CloseAccount` and `organizations:LeaveOrganization`**, so the member
  account holding the vault cannot be closed or pulled out of the organization
  without the management account's involvement. (Organizations created via the
  console after **2026-07-10** receive this SCP at the root automatically; older
  or CLI/CloudFormation-created organizations must add it manually.)
- **Protect the management account and root separately.** SCPs do **not** apply
  to the management account, so it needs hardware-MFA root, minimal use, and
  tight access. Consider tag-based closure exemptions and a dedicated
  "transition" OU (free of the deny-close SCP) for legitimate offboarding
  (break-glass).

**The full recipe for "greater than a permanent delete"** is therefore:
COMPLIANCE-mode Object Lock + bucket default retention (object-level immutability
for everyone, including root) **plus** an Organizations SCP denying account
closure (removing the only pre-expiry exit). That combination takes you from "one
object can't be deleted" to "this evidence practically cannot be erased early by
anyone in the organization without a management-account-level, audited action."

---

## 9. How to explain this to an auditor

Frame WORM vs. IAM as **two different questions the control answers**, in two
different layers:

> "IAM controls answer *'who is allowed to make this request?'* — identity-scoped
> and mutable: a sufficiently privileged principal can rewrite the policy and then
> do the thing it forbade. Object Lock answers a different question — *'can this
> object be altered or destroyed at all, right now, by anyone?'* — and for a
> COMPLIANCE-mode object inside its retention window the answer is no, independent
> of identity, including the account root. The retention is a property of the
> data, enforced by the storage service, not a rule attached to a caller."

Then the assertion the auditor actually cares about, stated **honestly**:

> "Our threat model includes the privileged insider and the attacker who
> compromises admin credentials. An IAM deny-delete does not defend against that
> actor — they can lift it. COMPLIANCE-mode Object Lock does: within the retention
> period the evidence cannot be deleted, overwritten, or its retention shortened
> by any principal. The bounded exceptions are (a) retention expiry, after which
> normal deletion applies, and (b) destroying the entire AWS account, which
> carries a ~90-day recoverable grace period and full audit trail. We disclose
> those; we do not claim eternal immutability."

Auditors trust that framing **more** than "it can never be deleted," because the
latter is false and they know it. The credible claim is a **specific,
time-bounded, identity-independent guarantee with its exceptions named** — plus
evidence you can show: the bucket's Object Lock configuration, the object's
retention (`aws s3api get-object-retention`), and the Cohasset assessment mapping
it to the WORM rules. That last item matters because it is an *independent* party
attesting the mechanism meets the requirement — you are not asking the auditor to
take AWS's or your word for it.

---

## 10. The threat-model takeaway

The honest limit of "root can't touch it" is this: a determined root user **can**
destroy compliance-locked evidence early — but only by **destroying the entire
account**, and only after a ~90-day, reversible, highly visible delay. That is a
categorically different act than "quietly delete this one incriminating object."
It:

- takes down **everything** (every workload, bucket, and billing relationship) —
  not surgical;
- is loud and slow (~90-day recoverable window, closure notifications, audit
  trail);
- cannot be targeted at a single object.

Which is exactly why COMPLIANCE-mode WORM is a strong evidence-preservation
control **despite** this escape hatch. You have not made deletion *impossible* —
you have raised its cost from "one `aws s3 rm` command an insider runs in
seconds" to "burn down the entire AWS account and wait 90 days." For a
chain-of-custody argument, that is the precise, defensible claim:

> Not *"it can never be deleted,"* but *"it cannot be deleted without an
> account-destroying, reversible, ~90-day, fully-audited act."*

---

## 11. Practical notes for anyone applying this

- Use **COMPLIANCE** mode for evidence you must be able to defend as un-tamperable
  by insiders; use **GOVERNANCE** mode only where a documented, permissioned
  override is acceptable.
- Enable Object Lock at bucket creation (cleanest) **or** on an existing
  versioned bucket via `PutObjectLockConfiguration` (supported since Nov 2023).
- Object Lock **requires versioning**; keep it enabled.
- Prefer a **bucket default retention** rule so every new object is auto-locked —
  a per-object approach can leave an unprotected write if someone forgets it.
- Close the account-closure hatch with an **AWS Organizations SCP** denying
  `account:CloseAccount` and `organizations:LeaveOrganization`, and protect the
  management account/root separately (SCPs don't apply to the management account).
- The retention *period* is a compliance decision. A demo value like `days = 1`
  (used here so the stretch costs pennies and tears down the same day) is **not**
  a compliant retention — real 17a-4-style retention is measured in years.
- Object Lock is the **control**, not automatic compliance. Meeting a regulation
  also requires an appropriate retention period, a designated third party where
  the rule calls for one, and the surrounding audit process.
- If you add SSE-KMS with a customer-managed key, remember you have introduced a
  crypto-shredding deletion vector that sits outside Object Lock.

---

## Sources

- AWS — *Locking objects with S3 Object Lock*:
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html>
- AWS — *Object Lock considerations* (Compliance mode; account deletion as the
  only pre-expiry delete path):
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-managing.html>
- AWS re:Post — *Are objects under compliance mode with retention period
  deletable?*:
  <https://repost.aws/questions/QUIYAWBZdLTMimGlM2MIhTUQ/are-objects-under-compliance-mode-with-retention-period-deletable>
- AWS — *Configuring S3 Object Lock* (default vs per-object retention, CLI/API):
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-configure.html>
- AWS — *Enabling S3 Object Lock on existing buckets* (2023-11):
  <https://aws.amazon.com/about-aws/whats-new/2023/11/amazon-s3-enabling-object-lock-buckets/>
- AWS Organizations — *Protecting member accounts from closure* (deny
  `account:CloseAccount` / `organizations:LeaveOrganization`):
  <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_account_close_policy.html>
- AWS Cloud Operations Blog — *Essential security controls to prevent
  unauthorized account removal in AWS Organizations*:
  <https://aws.amazon.com/blogs/mt/essential-security-controls-to-prevent-unauthorized-account-removal-in-aws-organizations/>
- AWS — *SEC Rule 17a-4(f) / FINRA / CFTC compliance overview* (Cohasset
  Associates assessment): <https://aws.amazon.com/compliance/secrule17a-4f/>
- Cohasset Associates — *Amazon S3 Compliance Assessment (2025)*:
  <https://d1.awsstatic.com/onedam/marketing-channels/website/aws/en_US/whitepapers/compliance/Amazon-S3-Compliance-Assessment-2025.pdf>
- NIST SP 800-53 Rev. 5 — controls **AU-9** (Protection of Audit Information) and
  **AU-11** (Audit Record Retention).

---

*Prepared as part of the GRC Engineering Club 6-week challenge (Week 4 — Evidence
You Can Trust). The AWS behavioral claims here were verified against the sources
above; the KMS crypto-shredding point applies only where SSE-KMS with a
customer-managed key is configured, which the reference vault does not use.*
