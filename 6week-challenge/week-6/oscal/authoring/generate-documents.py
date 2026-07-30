#!/usr/bin/env python3
"""Authoring script for the week-6 OSCAL documents.

    !!  ONE-SHOT. The committed JSON is authoritative, not this script.  !!

Re-running it mints fresh v4 UUIDs and a fresh last-modified, producing
documents that are semantically identical to the committed ones but that will
not match their signatures (see ../../sign-oscal.sh). Run it to regenerate from
scratch or to re-derive the documents after editing the content below — then
re-sign. Do not run it as part of CI.

It exists for two reasons. First, every UUID here is a generated v4: OSCAL
rejects anything else, and hand-writing them is the most common way a trestle
document fails validation. Second, the four implemented-requirements share one
source of truth for the commit pin, the namespace, and the evidence URIs, so a
link cannot be right in three places and stale in the fourth.

This is the opposite of ../../oscal-from-conftest.py, deliberately. That
converter runs unattended in CI on every gate run, so its UUIDs are SHA-256
derived from content (see stable_uuid there) and its output is byte-reproducible
— a reviewer can regenerate the document and diff it against the committed one.
This script is run by hand, rarely, and its output is signed afterwards; fresh
v4 UUIDs are correct here for the same reason hash-derived ones are correct
there. Reproducibility belongs where a machine re-runs it unattended.
"""
import datetime
import json
import pathlib
import uuid

OSCAL_VERSION = "1.2.1"
NOW = datetime.datetime.now(datetime.timezone.utc).isoformat()

REPO = "sevenbelowllc/grc-engineering-club"
# Content-addressed pin. Every evidence and source link below resolves at this
# exact commit, so the document keeps meaning after the branch moves on.
PIN = "1d97be7f0763223db7a42b805375c6302fd24e14"
RAW = f"https://raw.githubusercontent.com/{REPO}/{PIN}"
BLOB = f"https://github.com/{REPO}/blob/{PIN}"
VAULT = "s3://grc-challenge-evidence-vault-f11fcaca/manual/2026-07-26"

NS = "https://sevenbelow.com/ns/oscal"
NIST_NS = "http://csrc.nist.gov/ns/oscal"
CATALOG = (
    "https://raw.githubusercontent.com/usnistgov/oscal-content/main"
    "/nist.gov/SP800-53/rev5/json/NIST_SP-800-53_rev5_catalog.json"
)

VERIFY = "6week-challenge/week-4/verify-evidence.sh"


def u():
    return str(uuid.uuid4())


def prop(name, value, ns=NS, **kw):
    p = {"name": name, "ns": ns, "value": value}
    p.update(kw)
    return p


def evidence_links(bundle_path, vault_key, what):
    """The two halves of an evidence link: a copy anyone can fetch, and a copy
    nobody can delete. Either alone is a weaker claim than both together."""
    return [
        {
            "href": f"{RAW}/{bundle_path}",
            "rel": "evidence",
            "media-type": "application/gzip",
            "text": f"Signed evidence bundle ({what}) — public, fetchable without credentials.",
        },
        {
            "href": f"{VAULT}/{vault_key}",
            "rel": "evidence",
            "media-type": "application/gzip",
            "text": (
                f"The same bundle in an S3 Object Lock COMPLIANCE vault ({what}) — "
                "undeletable by any principal, including the account root, until "
                "its retention expires."
            ),
        },
        {
            "href": f"{BLOB}/{VERIFY}",
            "rel": "verification",
            "media-type": "text/x-shellscript",
            "text": (
                "Verifier for the linked bundle. Checks integrity (recomputed SHA-256 "
                "against the sidecar), authenticity and timeliness (cosign verify-blob "
                "against a pinned signer identity and the Rekor transparency log), and "
                "preservation (Object Lock retention on the vault object). Prints "
                "CHAIN INTACT only when every executed check passes."
            ),
        },
    ]


def signer_props(issuer, identity_regexp):
    """Who signed the linked evidence, stated in the document.

    cosign verification requires pinning both the OIDC issuer and the certificate
    identity — an unpinned `verify-blob` will happily accept a signature from
    anyone at all, which is verification in form only. Those pins are part of the
    claim, so they belong in the document rather than in a reader's head or a
    verifier's hardcoded default. traverse.sh reads them from here.
    """
    return [
        prop("evidence-signer-issuer", issuer, **{"class": "cosign"}),
        prop("evidence-signer-identity", identity_regexp, **{"class": "cosign"},
             remarks="Regular expression, matched against the signing certificate's identity."),
    ]


CI_SIGNER = signer_props(
    "https://token.actions.githubusercontent.com",
    r"^https://github.com/sevenbelowllc/grc-engineering-club/\.github/workflows/grc-gate\.yml@refs/.*$",
)
# Week 5's bundle was signed from a workstation rather than in CI, so its
# certificate carries a personal Google identity instead of a workflow identity.
# The address is not a leak: keyless signing publishes it to the Rekor
# transparency log by design, and verifying the signature requires knowing it.
LOCAL_SIGNER = signer_props("https://accounts.google.com", r"^dkramer@sevenbelow\.com$")

W4_EVIDENCE = ("6week-challenge/week-4/evidence/evidence.tar.gz", "evidence.tar.gz",
               "week 4: terraform plan + conftest verdicts, signed in CI")
W5_EVIDENCE = ("6week-challenge/week-5/evidence/week5-evidence.tar.gz", "week5-evidence.tar.gz",
               "week 5: live AWS trail status, Security Hub findings, replica listing")

REQUIREMENTS = [
    {
        "control-id": "sc-28",
        "description": (
            "Every S3 bucket in the baseline carries a server-side encryption "
            "configuration that sets AES256 as the default algorithm and enables an "
            "S3 bucket key. Encryption is a property of the bucket rather than of the "
            "caller, so it covers every object written by every principal — there is "
            "no code path that writes an unencrypted object.\n\n"
            "The control is enforced before it can be violated. The Rego rule "
            "compliance.sc28_aws denies any aws_s3_bucket that no "
            "aws_s3_bucket_server_side_encryption_configuration references, and the CI "
            "gate runs it against the Terraform plan on every pull request. The rule "
            "matches by resource reference, not by bucket name, because the bucket name "
            "carries a random suffix that is unknown until apply; matching by value "
            "would pass a plan that a name-matching rule could not evaluate at all."
        ),
        "props": [
            prop("implementation-status", "implemented", ns=NIST_NS),
            prop("terraform-resource", "aws_s3_bucket_server_side_encryption_configuration.primary",
                 **{"class": "aws-resource"}),
            prop("terraform-resource", "aws_s3_bucket_server_side_encryption_configuration.log",
                 **{"class": "aws-resource"}),
            prop("policy-package", "compliance.sc28_aws", **{"class": "rego"}),
            prop("verification-point", "plan-time",
                 remarks="Enforced by the CI gate before apply, not detected after the fact."),
        ] + CI_SIGNER,
        "links": [
            {
                "href": f"{BLOB}/6week-challenge/week-1/solution/main.tf#L46-L64",
                "rel": "reference",
                "text": "Terraform resources that implement the control.",
            },
            {
                "href": f"{BLOB}/6week-challenge/week-3/policies/sc28_encryption_aws.rego",
                "rel": "reference",
                "text": "Rego rule the CI gate evaluates against the plan.",
            },
        ] + evidence_links(*W4_EVIDENCE),
    },
    {
        "control-id": "ac-3",
        "description": (
            "Public access is blocked on every bucket with all four S3 public-access "
            "flags set to true: block_public_acls, block_public_policy, "
            "ignore_public_acls and restrict_public_buckets. All four are set because "
            "they close four independent paths to public exposure — blocking new public "
            "ACLs does nothing about an ACL that already exists, and blocking a public "
            "bucket policy does nothing about ACLs at all. Three of four is a bucket "
            "that is still reachable.\n\n"
            "compliance.ac3_aws denies any aws_s3_bucket that no public access block "
            "references, and then reads the block's planned values to confirm all four "
            "flags are literally true. A block that exists but sets only some flags "
            "fails the gate rather than passing it on the strength of being present."
        ),
        "props": [
            prop("implementation-status", "implemented", ns=NIST_NS),
            prop("terraform-resource", "aws_s3_bucket_public_access_block.primary",
                 **{"class": "aws-resource"}),
            prop("terraform-resource", "aws_s3_bucket_public_access_block.log",
                 **{"class": "aws-resource"}),
            prop("policy-package", "compliance.ac3_aws", **{"class": "rego"}),
            prop("verification-point", "plan-time",
                 remarks="Enforced by the CI gate before apply, not detected after the fact."),
        ] + CI_SIGNER,
        "links": [
            {
                "href": f"{BLOB}/6week-challenge/week-1/solution/main.tf#L90-L104",
                "rel": "reference",
                "text": "Terraform resources that implement the control.",
            },
            {
                "href": f"{BLOB}/6week-challenge/week-3/policies/ac3_no_public_aws.rego",
                "rel": "reference",
                "text": "Rego rule the CI gate evaluates against the plan.",
            },
        ] + evidence_links(*W4_EVIDENCE),
    },
    {
        "control-id": "au-3",
        "description": (
            "A multi-region CloudTrail trail records management events from every "
            "region into a dedicated log bucket, with log-file validation enabled. "
            "CloudTrail records carry the fields AU-3 asks for — event type and time, "
            "the source of the request, the resource acted on, and the outcome — and "
            "log-file validation adds an hourly signed digest so a deleted or altered "
            "log file is detectable rather than merely absent.\n\n"
            "Unlike the other three controls in this set, AU-3 is verified at runtime "
            "rather than at plan time. See the remarks."
        ),
        "remarks": (
            "AU-3 is the one control here with no Rego rule, and that is a deliberate "
            "statement about what a plan can prove. A Terraform plan can show that an "
            "aws_cloudtrail resource will be created with the right arguments. It "
            "cannot show that the trail is delivering records, because delivery is a "
            "runtime property of a system that does not exist yet at plan time. "
            "Writing a plan-time rule for AU-3 would produce a green gate that "
            "attests to nothing.\n\n"
            "The evidence linked here is therefore captured output from the running "
            "account — aws cloudtrail get-trail-status showing IsLogging true with "
            "recent log and digest delivery timestamps, alongside AWS Security Hub "
            "findings for the same account. That is a narrower claim than the plan-time "
            "controls make (it is true of one moment, not of every future pull request) "
            "and a stronger one (it is about the system, not about the intent). The "
            "gap between the two is the assurance boundary this pipeline documents "
            "rather than papers over."
        ),
        "props": [
            prop("implementation-status", "implemented", ns=NIST_NS),
            prop("terraform-resource", "aws_cloudtrail.this", **{"class": "aws-resource"}),
            prop("verification-point", "runtime",
                 remarks=("No plan-time policy rule. Delivery is observable only against "
                          "a running trail.")),
        ] + LOCAL_SIGNER,
        "links": [
            {
                "href": f"{BLOB}/6week-challenge/week-5/terraform/cloudtrail.tf#L51-L58",
                "rel": "reference",
                "text": "Terraform resource that implements the control.",
            },
        ] + evidence_links(*W5_EVIDENCE),
    },
    {
        "control-id": "cm-6",
        "description": (
            "Configuration settings are enforced two ways. The AWS provider's "
            "default_tags block stamps Project, Environment, ManagedBy and "
            "ComplianceScope onto every taggable resource, so a resource added later "
            "cannot silently miss them — the tags are a property of the provider, not "
            "of the author's memory. Versioning is enabled on the buckets so prior "
            "object states stay recoverable and auditable.\n\n"
            "compliance.cm6_aws denies any resource whose plan emits a tags_all or tags "
            "map missing one of the four required tags. It uses the provider's computed "
            "tags_all attribute as the definition of 'taggable' rather than a hardcoded "
            "list of resource types: tags_all appears on exactly the taggable types, so "
            "the rule stays correct as the provider adds resources, and a hardcoded "
            "list would drift into silently skipping them."
        ),
        "props": [
            prop("implementation-status", "implemented", ns=NIST_NS),
            prop("terraform-resource", "provider.aws.default_tags", **{"class": "aws-resource"}),
            prop("terraform-resource", "aws_s3_bucket_versioning.primary", **{"class": "aws-resource"}),
            prop("terraform-resource", "aws_s3_bucket_versioning.log", **{"class": "aws-resource"}),
            prop("policy-package", "compliance.cm6_aws", **{"class": "rego"}),
            prop("verification-point", "plan-time",
                 remarks="Enforced by the CI gate before apply, not detected after the fact."),
        ] + CI_SIGNER,
        "links": [
            {
                "href": f"{BLOB}/6week-challenge/week-1/solution/main.tf#L16-L23",
                "rel": "reference",
                "text": "Provider default_tags block — the tagging half of the control.",
            },
            {
                "href": f"{BLOB}/6week-challenge/week-1/solution/main.tf#L70-L84",
                "rel": "reference",
                "text": "Bucket versioning — the recoverable-configuration half.",
            },
            {
                "href": f"{BLOB}/6week-challenge/week-3/policies/cm6_required_tags_aws.rego",
                "rel": "reference",
                "text": "Rego rule the CI gate evaluates against the plan.",
            },
        ] + evidence_links(*W4_EVIDENCE),
    },
]

PARTY_UUID = u()

METADATA_COMMON = {
    "last-modified": NOW,
    "version": "1.0.0",
    "oscal-version": OSCAL_VERSION,
    "roles": [
        {
            "id": "provider",
            "title": "Pipeline provider",
            "description": "Builds and operates the pipeline, and stands behind the claims in this document.",
        }
    ],
    "parties": [
        {
            "uuid": PARTY_UUID,
            "type": "organization",
            "name": "Sevenbelow LLC",
            "links": [{"href": f"https://github.com/{REPO}", "rel": "reference"}],
        }
    ],
    "responsible-parties": [{"role-id": "provider", "party-uuids": [PARTY_UUID]}],
}

component_definition = {
    "component-definition": {
        "uuid": u(),
        "metadata": dict(
            METADATA_COMMON,
            title="GRC Engineering Pipeline — NIST SP 800-53 Rev 5 control implementation",
            remarks=(
                "Machine-readable statement of the controls a six-week build of an AWS "
                "compliance pipeline implements, and of the evidence that proves each "
                "one. Every implemented-requirement names the Terraform resource that "
                "does the work, the Rego rule that gates it where one exists, and a "
                "signed evidence bundle that can be fetched and verified without "
                "contacting the author.\n\n"
                "Companion profile: grc-pipeline-controls, which selects exactly these "
                "four control IDs from the NIST catalog."
            ),
        ),
        "components": [
            {
                "uuid": u(),
                "type": "service",
                "title": "GRC Engineering Pipeline (Terraform, OPA/Conftest, cosign, AWS)",
                "description": (
                    "A pipeline that provisions an AWS baseline with Terraform, proves its "
                    "control state with Rego policy evaluated against the plan, gates every "
                    "pull request on that proof, signs the resulting evidence with keyless "
                    "cosign and records it in the Rekor transparency log, preserves it in an "
                    "S3 Object Lock COMPLIANCE vault, and monitors the running account with "
                    "CloudTrail and Security Hub."
                ),
                "purpose": (
                    "Make the control state of an AWS account something a third party can "
                    "verify from published artifacts, without a meeting, a screenshot "
                    "request, or trust in the operator."
                ),
                "props": [
                    prop("cloud-provider", "aws"),
                    prop("iac-tool", "terraform"),
                    prop("policy-engine", "open-policy-agent"),
                ],
                "links": [
                    {
                        "href": f"https://github.com/{REPO}",
                        "rel": "reference",
                        "text": "Source repository. Every link in this document resolves inside it.",
                    }
                ],
                "responsible-roles": [{"role-id": "provider", "party-uuids": [PARTY_UUID]}],
                "control-implementations": [
                    {
                        "uuid": u(),
                        "source": CATALOG,
                        "description": (
                            "Controls this pipeline implements against NIST SP 800-53 Rev 5. "
                            "Three of the four are enforced at plan time by the CI gate and "
                            "cannot regress without failing a pull request; the fourth "
                            "(AU-3) is verified at runtime, and its implemented-requirement "
                            "says why."
                        ),
                        "implemented-requirements": [
                            dict(r, uuid=u()) for r in REQUIREMENTS
                        ],
                    }
                ],
            }
        ],
    }
}

profile = {
    "profile": {
        "uuid": u(),
        "metadata": dict(
            METADATA_COMMON,
            title="GRC Engineering Pipeline — controls in scope",
            remarks=(
                "The claim, stated as a selection. Four control IDs from NIST SP 800-53 "
                "Rev 5 and nothing else: the controls this pipeline actually implements "
                "and produces evidence for. Controls the build touches incidentally — "
                "AU-9 from versioning the log bucket, AU-10 from CloudTrail log-file "
                "validation, SI-4 from Security Hub — are deliberately excluded. A "
                "profile that claims everything it brushes against is not a scope "
                "statement, it is a wish list, and every unbacked entry devalues the "
                "backed ones.\n\n"
                "Companion component definition: grc-pipeline, which says how each "
                "selected control is implemented and links the evidence."
            ),
        ),
        "imports": [
            {
                "href": CATALOG,
                "include-controls": [
                    {"with-ids": ["ac-3", "au-3", "cm-6", "sc-28"]}
                ],
            }
        ],
        "merge": {"as-is": True},
    }
}

# ---------------------------------------------------------------------------
# Assessment plan.
#
# OSCAL makes import-ap a REQUIRED field on assessment-results: results are, by
# construction, the answer to a plan. So the converter that turns conftest
# verdicts into assessment-results needs a plan to point at, and this is it.
#
# It is also the honest place to state the method split. Three controls are
# assessed by automated policy evaluation against the Terraform plan on every
# pull request; AU-3 is assessed by examining captured runtime output. Both are
# real assessment methods and they prove different things.
# ---------------------------------------------------------------------------
CD_RESOURCE_UUID = u()

assessment_plan = {
    "assessment-plan": {
        "uuid": u(),
        "metadata": dict(
            METADATA_COMMON,
            title="GRC Engineering Pipeline — continuous assessment plan",
            remarks=(
                "What gets assessed, how, and how often. The assessment is not a "
                "point-in-time exercise: the plan-time portion runs on every pull "
                "request as a required status check, so its results are regenerated "
                "continuously rather than commissioned annually."
            ),
        ),
        # OSCAL expects an SSP here. This build does not have one, and inventing a
        # thin SSP purely to satisfy the field would be worse than saying so: the
        # thing being assessed is a reusable pipeline component, not an
        # authorization boundary with a system owner and a categorisation. The
        # reference therefore resolves to a back-matter resource that points at the
        # component definition, which plays the SSP's role here, and the remarks
        # below say exactly that rather than leaving a reader to infer it.
        "import-ssp": {
            "href": f"#{CD_RESOURCE_UUID}",
            "remarks": (
                "Not an SSP. This assessment targets the component definition "
                "'grc-pipeline', which describes a reusable pipeline rather than an "
                "authorized system. OSCAL requires import-ssp on an assessment plan, "
                "so the reference points at a back-matter resource for the component "
                "definition. Read as: the subject of this assessment is the component, "
                "and no system authorization boundary is being claimed."
            ),
        },
        "reviewed-controls": {
            "control-selections": [
                {
                    "description": (
                        "Assessed on every pull request by automated policy evaluation "
                        "(Conftest/OPA) against the Terraform plan, before apply."
                    ),
                    "include-controls": [
                        {"control-id": "ac-3"},
                        {"control-id": "cm-6"},
                        {"control-id": "sc-28"},
                    ],
                },
                {
                    "description": (
                        "Assessed by examining captured output from the running AWS "
                        "account. Not evaluable at plan time — see the remarks."
                    ),
                    "include-controls": [{"control-id": "au-3"}],
                },
            ],
            "remarks": (
                "The split between the two selections is the assurance boundary of "
                "this pipeline, stated in the model rather than in a footnote.\n\n"
                "The first selection is enforcement: a pull request that would remove "
                "bucket encryption fails the gate and cannot merge, so a violation "
                "never reaches the account. That is strong, and it is also entirely a "
                "claim about intent — it assesses what Terraform says it will do.\n\n"
                "The second selection is observation: CloudTrail delivery is a runtime "
                "property, so the only way to assess it is to look at the running "
                "system. That is a claim about reality, and it is true of the moment "
                "it was captured rather than of every future change.\n\n"
                "Neither method subsumes the other. Drift introduced outside Terraform "
                "is invisible to the first and visible to the second only if Security "
                "Hub or Config happens to have a rule for it."
            ),
        },
        "assessment-assets": {
            "assessment-platforms": [
                {
                    "uuid": u(),
                    "title": "GitHub Actions grc-gate workflow",
                    "remarks": (
                        "Runs terraform validate, terraform plan -json, conftest against "
                        "the Rego policies, opa test on the policy unit tests, and "
                        "trestle validate on these OSCAL documents; then signs the "
                        "resulting evidence bundle with keyless cosign and deposits it "
                        "in the WORM vault. The assessor is a workflow, not a person, "
                        "which is why its results are reproducible."
                    ),
                }
            ]
        },
        "back-matter": {
            "resources": [
                {
                    "uuid": CD_RESOURCE_UUID,
                    "title": "Component definition: GRC Engineering Pipeline",
                    "description": (
                        "The subject of this assessment. Stands in for the SSP that "
                        "OSCAL's import-ssp field expects."
                    ),
                    "rlinks": [
                        {
                            "href": (
                                f"{RAW}/6week-challenge/week-6/oscal/component-definitions"
                                "/grc-pipeline/component-definition.json"
                            ),
                            "media-type": "application/json",
                        }
                    ],
                }
            ]
        },
    }
}

# Resolve relative to this file, not to the caller's cwd — the trestle workspace
# root is authoring/'s parent wherever the repo happens to be cloned.
ROOT = pathlib.Path(__file__).resolve().parent.parent


def write(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {path}")


write(ROOT / "component-definitions" / "grc-pipeline" / "component-definition.json",
      component_definition)
write(ROOT / "profiles" / "grc-pipeline-controls" / "profile.json", profile)
write(ROOT / "assessment-plans" / "grc-pipeline-assessment" / "assessment-plan.json",
      assessment_plan)
