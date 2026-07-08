# METADATA
# title: AC-3 - Access Enforcement (AWS S3 public access block)
# description: Every aws_s3_bucket must have a public access block with all four flags true.
# custom:
#   control_id: AC-3
#   framework: nist-800-53
#   severity: critical
#   remediation: Add aws_s3_bucket_public_access_block referencing the bucket, all four flags true.
package compliance.ac3_aws

import rego.v1

bucket_type := "aws_s3_bucket"

pab_type := "aws_s3_bucket_public_access_block"

required_flags := {"block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"}

# Every resource declared under configuration, at any module depth (see
# sc28_encryption_aws.rego for the walk technique).
config_resources contains r if {
	walk(input.configuration, [path, value])
	path[count(path) - 1] == "resources"
	some r in value
}

# Every resource in planned_values, at any module depth (root_module.resources
# plus any child_modules[...].resources).
planned_resources contains r if {
	walk(input.planned_values, [path, value])
	path[count(path) - 1] == "resources"
	some r in value
}

# AC-3: an aws_s3_bucket is denied unless it has a matching public access block
# whose four flags are all true. Fail-closed: a bucket whose public access block
# is missing, unmatched in planned_values, or has any flag != true is denied.
deny contains msg if {
	some bucket in config_resources
	bucket.type == bucket_type
	bucket_addr := sprintf("aws_s3_bucket.%s", [bucket.name])
	not has_compliant_pab(bucket_addr)

	msg := sprintf(
		"AC-3: aws_s3_bucket '%s' is missing a public access block with all four flags set to true. Remediation: add an aws_s3_bucket_public_access_block referencing it with block_public_acls, block_public_policy, ignore_public_acls and restrict_public_buckets = true.",
		[bucket.name],
	)
}

# True only if some public access block references this bucket (match by
# reference, config side) AND its planned values set all four flags to true.
has_compliant_pab(bucket_addr) if {
	some pab in config_resources
	pab.type == pab_type
	some ref in pab.expressions.bucket.references
	references_bucket(ref, bucket_addr)

	# Bridge from configuration to planned_values by the block's address to read
	# the concrete flag values Terraform intends to set.
	pab_addr := sprintf("%s.%s", [pab.type, pab.name])
	values := planned_values_for(pab_addr)
	all_flags_true(values)
}

planned_values_for(addr) := values if {
	some r in planned_resources
	r.address == addr
	values := r.values
}

all_flags_true(values) if {
	every flag in required_flags {
		values[flag] == true
	}
}

references_bucket(ref, bucket_addr) if ref == bucket_addr

references_bucket(ref, bucket_addr) if startswith(ref, sprintf("%s.", [bucket_addr]))
