# METADATA
# title: CM-6 - Configuration Settings (AWS required tags)
# description: Taggable resources must carry the four required compliance tags.
# custom:
#   control_id: CM-6
#   framework: nist-800-53
#   severity: medium
#   remediation: Add the missing tags or rely on provider default_tags.
package compliance.cm6_aws

import rego.v1

required := {"Project", "Environment", "ManagedBy", "ComplianceScope"}

# Every resource in planned_values, at any module depth (root_module.resources
# plus any child_modules[...].resources). `walk` yields (path, value) for every
# node; we keep arrays whose final path element is "resources", so nested
# modules are not silently skipped.
planned_resources contains r if {
	walk(input.planned_values, [path, value])
	path[count(path) - 1] == "resources"
	some r in value
}

# CM-6: a taggable resource missing any required tag is denied.
#
# "Taggable" is defined as: the plan emits a tags_all (or tags) map for the
# resource. The AWS provider models tags_all as a computed schema attribute on
# exactly the taggable resource types, so its presence is an authoritative,
# self-maintaining signal — no hardcoded resource-type list to drift. Because
# tags_all is computed, provider default_tags populate it even when a resource
# declares no tags block, so an untagged-but-taggable resource still surfaces
# (as an empty or partial map) and is correctly caught. Non-taggable resources
# (encryption config, public access block, ACL, logging) have neither key and
# are skipped.
deny contains msg if {
	some r in planned_resources
	tags := effective_tags(r)
	missing := required - object.keys(tags)
	count(missing) > 0

	msg := sprintf(
		"CM-6: resource '%s' is missing required tag(s): %s. Remediation: add the tag(s) or rely on provider default_tags.",
		[r.address, concat(", ", sort(missing))],
	)
}

# Prefer the merged tags_all; fall back to tags. Guarding on is_object skips the
# plan-time-unknown case (tags_all null) and non-taggable resources.
effective_tags(r) := r.values.tags_all if is_object(r.values.tags_all)

effective_tags(r) := r.values.tags if {
	not is_object(r.values.tags_all)
	is_object(r.values.tags)
}
