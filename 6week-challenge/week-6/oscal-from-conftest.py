#!/usr/bin/env python3
"""Turn Conftest verdicts into an OSCAL assessment-results document.

    conftest --output json  →  assessment-results.json

This is the join between the two halves of the six-week build. Weeks 1-5 produce
proof in engineering formats: a Terraform plan, Rego rules, a JSON verdict file,
a signed tarball. Week 6's component definition states the same controls in the
format an assessor consumes. Nothing yet carries the *outcome* across. A human
reading `"successes": 1` next to `compliance.sc28_aws` and concluding "SC-28 is
satisfied" is doing a translation by hand, every time, and that translation is
exactly the manual step the whole pipeline exists to delete.

This script does it mechanically, and its central design decision is that

    THE CONTROL MAPPING IS NOT IN THIS FILE.

There is no dict here saying compliance.sc28_aws means sc-28. That mapping lives
in the component definition, as a `policy-package` prop on each
implemented-requirement, because that is the document whose job is to say how a
control is implemented. The converter reads it out of the OSCAL at runtime. Add
a control to the component definition and its verdicts start converting; rename
a Rego package without updating the component and the converter fails loudly
instead of silently dropping a control from the results.

That inversion is the point. A converter with a hardcoded table is a third place
the truth lives, and the third place is always the one that goes stale.


Usage
-----
    ./oscal-from-conftest.py \
        --conftest    ../week-3/evidence/conftest-results.json \
        --component   oscal/component-definitions/grc-pipeline/component-definition.json \
        --plan-href   ../../assessment-plans/grc-pipeline-assessment/assessment-plan.json \
        --evidence    https://raw.githubusercontent.com/.../evidence.tar.gz \
        --evidence    s3://vault/.../evidence.tar.gz \
        --assessed-at 2026-07-26T18:00:00+00:00 \
        -o oscal/assessment-results/gate-run/assessment-results.json

Exit codes: 0 written, 2 usage/input error, 3 mapping error (see below).
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import pathlib
import sys
import uuid

OSCAL_VERSION = "1.2.1"
NS = "https://sevenbelow.com/ns/oscal"
NIST_NS = "http://csrc.nist.gov/ns/oscal"

# Distinguishes this converter's derived identifiers from anyone else's. Any
# fixed string works; it only has to be stable.
UUID_SEED = "sevenbelow/grc-engineering-club/oscal-from-conftest/v1"


class MappingError(Exception):
    """The component definition and the conftest output disagree."""


def stable_uuid(*parts: str) -> str:
    """A deterministic UUID that still satisfies OSCAL's v4-only syntax.

    Two requirements collide here.

    OSCAL's `uuid` datatype pins the version nibble to 4 — the regex is
    literally `[4][0-9A-Fa-f]{3}` in the third group — so uuid5, the obvious
    tool for deriving an identifier from a name, is rejected outright.

    But a converter that mints `uuid4()` produces a different document from
    identical input on every run. That makes the output impossible to diff (a
    reviewer cannot tell a changed verdict from a changed random number),
    impossible to reproduce (nobody can regenerate the committed artifact and
    confirm it matches), and noisy in git.

    So: derive the bytes by hash, then set the version and variant bits to what
    a v4 UUID would carry. The result is a hash-derived identifier wearing v4's
    syntax. It is not a random UUID and this docstring is the place that says
    so; what it is, is stable, and stability is what an audit artifact needs.

    The inputs deliberately include the assessment timestamp, so two runs over
    the same verdicts at different times are correctly distinct assessments,
    while a re-run of *the same* assessment reproduces byte for byte.
    """
    digest = hashlib.sha256("|".join((UUID_SEED,) + parts).encode()).digest()
    b = bytearray(digest[:16])
    b[6] = (b[6] & 0x0F) | 0x40  # version 4
    b[8] = (b[8] & 0x3F) | 0x80  # RFC 4122 variant
    return str(uuid.UUID(bytes=bytes(b)))


def load_json(path: pathlib.Path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        sys.exit(f"error: no such file: {path}")
    except json.JSONDecodeError as e:
        sys.exit(f"error: {path} is not valid JSON: {e}")


# ---------------------------------------------------------------------------
# Reading the mapping out of the component definition
# ---------------------------------------------------------------------------

def read_control_mapping(component_doc: dict) -> dict[str, dict]:
    """Build {rego package -> control info} from the component definition.

    Walks every implemented-requirement, and for each one that carries a
    `policy-package` prop records the control it belongs to. Requirements with
    no such prop — AU-3, which has no plan-time rule — are deliberately absent
    from the result: this converter reports what the policy gate found, and the
    gate found nothing about AU-3 because it does not test it.
    """
    mapping: dict[str, dict] = {}
    cd = component_doc["component-definition"]

    for component in cd.get("components", []):
        for impl in component.get("control-implementations", []):
            for req in impl.get("implemented-requirements", []):
                packages = [
                    p["value"] for p in req.get("props", [])
                    if p.get("name") == "policy-package"
                ]
                for pkg in packages:
                    if pkg in mapping and mapping[pkg]["control-id"] != req["control-id"]:
                        raise MappingError(
                            f"policy package {pkg!r} is claimed by two controls: "
                            f"{mapping[pkg]['control-id']} and {req['control-id']}. "
                            "One package cannot prove two controls without saying "
                            "which finding belongs to which."
                        )
                    mapping[pkg] = {
                        "control-id": req["control-id"],
                        "requirement-uuid": req["uuid"],
                        "source": impl.get("source", ""),
                    }
    return mapping


# ---------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------

def convert(conftest_results: list, mapping: dict, args) -> dict:
    assessed_at = args.assessed_at

    seen_packages = set()
    observations = []
    findings = []

    for entry in conftest_results:
        pkg = entry.get("namespace")
        if pkg is None:
            raise MappingError(
                "a conftest result has no 'namespace' field. Run conftest with "
                "--all-namespaces --output json."
            )
        if pkg not in mapping:
            # Loud, not lenient. An unmapped namespace means somebody added a
            # policy without adding it to the component definition, so a control
            # is being tested and the resulting assurance is going nowhere. That
            # is a defect in the mapping, and emitting a document that quietly
            # omits it would hide the defect behind a valid-looking artifact.
            raise MappingError(
                f"conftest reported on package {pkg!r}, which no "
                f"implemented-requirement in the component definition claims via a "
                f"'policy-package' prop.\n"
                f"  Known packages: {', '.join(sorted(mapping)) or '(none)'}\n"
                f"  Fix the component definition, not this script — the mapping is "
                f"supposed to live there."
            )
        seen_packages.add(pkg)

        info = mapping[pkg]
        control = info["control-id"]
        failures = entry.get("failures") or []
        warnings = entry.get("warnings") or []
        successes = entry.get("successes", 0)
        satisfied = not failures

        obs_uuid = stable_uuid("observation", assessed_at, pkg)
        observations.append(_observation(
            obs_uuid, pkg, control, entry, failures, warnings, successes, assessed_at, args))

        findings.append(_finding(
            stable_uuid("finding", assessed_at, control),
            control, info, satisfied, failures, obs_uuid, pkg))

    # The reverse check. Every package the component says gates a control must
    # appear in the conftest output; if one does not, the gate did not evaluate
    # it, and a control with no verdict is not a control that passed. Silence is
    # not consent.
    missing = set(mapping) - seen_packages
    if missing:
        raise MappingError(
            "the component definition claims these policy packages gate a control, "
            "but conftest reported no result for them:\n  "
            + "\n  ".join(f"{p}  (control {mapping[p]['control-id']})" for p in sorted(missing))
            + "\nAn absent verdict is not a passing verdict. Either the gate did not "
              "run the policy, or the component definition is claiming a rule that no "
              "longer exists."
        )

    assessed_controls = sorted({m["control-id"] for m in mapping.values()})

    result = {
        "uuid": stable_uuid("result", assessed_at),
        "title": "Automated policy assessment of the Terraform plan",
        "description": (
            "Conftest evaluated the repository's Rego policies against a Terraform "
            "plan and returned a verdict per policy package. This document is a "
            "mechanical translation of those verdicts — one observation per package, "
            "one finding per control — with no human judgement applied between the "
            "gate's output and the assessor's input."
        ),
        "start": assessed_at,
        "end": assessed_at,
        "reviewed-controls": {
            "control-selections": [
                {
                    "description": (
                        "Controls assessed by automated policy evaluation against the "
                        "Terraform plan, before apply."
                    ),
                    "include-controls": [{"control-id": c} for c in assessed_controls],
                }
            ],
            "remarks": (
                "This is a narrower set than the profile claims, and the difference is "
                "meaningful rather than an oversight. The profile scopes four controls; "
                "this assessment covers only those with a plan-time policy rule. AU-3 "
                "is assessed by a different method — examining captured runtime output — "
                "because trail delivery cannot be observed in a plan. Its evidence is "
                "linked from the component definition; it is simply not in this "
                "document, and a reader should not infer a verdict from its absence."
            ),
        },
        "observations": observations,
        "findings": findings,
    }

    return {
        "assessment-results": {
            "uuid": stable_uuid("assessment-results", assessed_at),
            "metadata": {
                "title": "GRC Engineering Pipeline — automated control assessment",
                "last-modified": assessed_at,
                "version": "1.0.0",
                "oscal-version": OSCAL_VERSION,
                "props": [
                    {"name": "generator", "ns": NS, "value": "oscal-from-conftest.py"},
                    {"name": "assessment-method", "ns": NS, "value": "automated-policy-evaluation"},
                ],
                "remarks": (
                    "Generated from conftest output by "
                    "6week-challenge/week-6/oscal-from-conftest.py. Do not hand-edit: "
                    "regenerate from the verdicts. The control mapping is read from "
                    "the component definition at conversion time, so this document "
                    "cannot claim a control the component does not implement."
                    + (f"\n\n{args.note}" if args.note else "")
                ),
            },
            "import-ap": {"href": args.plan_href},
            "results": [result],
        }
    }


def _observation(obs_uuid, pkg, control, entry, failures, warnings, successes,
                 assessed_at, args) -> dict:
    verdict = "no denials" if not failures else f"{len(failures)} denial(s)"
    description = (
        f"Conftest evaluated policy package {pkg} against "
        f"{entry.get('filename', 'the Terraform plan')} and returned {verdict} "
        f"({successes} rule(s) passed"
        + (f", {len(warnings)} warning(s)" if warnings else "")
        + ")."
    )
    if failures:
        description += "\n\nDenial messages, verbatim from the policy engine:\n" + "\n".join(
            f"  - {f.get('msg', '(no message)')}" for f in failures
        )

    obs = {
        "uuid": obs_uuid,
        "title": f"Conftest verdict for {pkg} ({control.upper()})",
        "description": description,
        "props": [
            {"name": "policy-package", "ns": NS, "value": pkg},
            {"name": "assessed-file", "ns": NS,
             "value": entry.get("filename", "(unspecified)")},
            {"name": "successes", "ns": NS, "value": str(successes)},
            {"name": "failures", "ns": NS, "value": str(len(failures))},
        ],
        # TEST, not EXAMINE: a policy engine executed a rule against an artifact
        # and produced a pass/fail, which is a test. EXAMINE would be the right
        # method for a human reading the plan and forming a view.
        "methods": ["TEST"],
        "types": ["control-objective"],
        "collected": assessed_at,
    }

    if args.evidence:
        obs["relevant-evidence"] = [
            {
                "href": href,
                "description": (
                    "Signed evidence bundle containing the Terraform plan this verdict "
                    "was computed from and the raw conftest output it was derived from. "
                    "Verify with 6week-challenge/week-4/verify-evidence.sh."
                ),
            }
            for href in args.evidence
        ]

    return obs


def _finding(finding_uuid, control, info, satisfied, failures, obs_uuid, pkg) -> dict:
    state = "satisfied" if satisfied else "not-satisfied"
    if satisfied:
        description = (
            f"{control.upper()} is satisfied. The policy rule that gates it "
            f"({pkg}) returned no denials against the assessed Terraform plan, and "
            f"that rule runs as a required status check on every pull request, so "
            f"the finding holds for the merged state of the repository rather than "
            f"for one manual run."
        )
    else:
        description = (
            f"{control.upper()} is NOT satisfied. The policy rule that gates it "
            f"({pkg}) returned {len(failures)} denial(s) against the assessed "
            f"Terraform plan. Because this rule is a required status check, a plan in "
            f"this state cannot merge — the finding records a change that was stopped, "
            f"not a control that is failing in production.\n\n"
            + "\n".join(f"  - {f.get('msg', '(no message)')}" for f in failures)
        )

    return {
        "uuid": finding_uuid,
        "title": f"{control.upper()} — {state}",
        "description": description,
        "target": {
            # objective-id, not statement-id: the assertion is about the control
            # objective as a whole, since a single Rego package evaluates the
            # control rather than one lettered statement within it.
            "type": "objective-id",
            "target-id": f"{control}_obj",
            "status": {"state": state},
        },
        # Closes the graph back to the component definition: this finding is a
        # verdict on that exact implemented-requirement, addressed by UUID rather
        # than by control ID, so it survives the control being re-scoped.
        "implementation-statement-uuid": info["requirement-uuid"],
        "related-observations": [{"observation-uuid": obs_uuid}],
    }


# ---------------------------------------------------------------------------

def iso8601(value: str) -> str:
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"not an ISO-8601 timestamp: {value!r} (e.g. 2026-07-26T18:00:00+00:00)")
    if parsed.tzinfo is None:
        raise argparse.ArgumentTypeError(
            f"timestamp {value!r} has no timezone. OSCAL requires an offset, because "
            "'when' is half of what an assessment record is worth.")
    return parsed.isoformat()


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="Convert conftest JSON output into an OSCAL assessment-results document.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--conftest", required=True, type=pathlib.Path,
                   help="conftest --output json results file")
    p.add_argument("--component", required=True, type=pathlib.Path,
                   help="component-definition.json — the source of the control mapping")
    p.add_argument("--plan-href", required=True,
                   help="href for import-ap, pointing at the assessment plan")
    p.add_argument("--evidence", action="append", default=[], metavar="URI",
                   help="evidence URI to attach to every observation; repeatable")
    p.add_argument("--assessed-at", required=True, type=iso8601,
                   help="ISO-8601 timestamp with offset for when the gate ran")
    p.add_argument("--note", default="",
                   help="extra sentence appended to the document's metadata remarks; "
                        "use it to label a run that is not the production one")
    p.add_argument("-o", "--output", required=True, type=pathlib.Path,
                   help="where to write the assessment-results document")
    args = p.parse_args(argv)

    conftest_results = load_json(args.conftest)
    if not isinstance(conftest_results, list):
        sys.exit("error: conftest output should be a JSON array. "
                 "Run: conftest test --all-namespaces --output json ...")

    component_doc = load_json(args.component)
    if "component-definition" not in component_doc:
        sys.exit(f"error: {args.component} is not an OSCAL component-definition")

    try:
        mapping = read_control_mapping(component_doc)
        if not mapping:
            raise MappingError(
                "no implemented-requirement in the component definition carries a "
                "'policy-package' prop, so there is nothing to map conftest output "
                "onto.")
        document = convert(conftest_results, mapping, args)
    except MappingError as e:
        print(f"mapping error: {e}", file=sys.stderr)
        return 3

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2) + "\n")

    findings = document["assessment-results"]["results"][0]["findings"]
    failed = [f for f in findings if f["target"]["status"]["state"] != "satisfied"]
    print(f"wrote {args.output}")
    print(f"  {len(findings)} finding(s): "
          f"{len(findings) - len(failed)} satisfied, {len(failed)} not satisfied")
    for f in failed:
        print(f"  NOT SATISFIED: {f['title']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
