# METADATA
# title: SC-28 - Encryption at Rest (AWS S3)
# description: Every aws_s3_bucket must have a matching server-side encryption configuration.
# custom:
#   control_id: SC-28
#   framework: nist-800-53
#   severity: high
#   remediation: Add aws_s3_bucket_server_side_encryption_configuration referencing the bucket.
package compliance.sc28_aws

import rego.v1

bucket_type := "aws_s3_bucket"

sse_type := "aws_s3_bucket_server_side_encryption_configuration"

# Every resource declared under configuration, at any module depth. `walk`
# yields (path, value) for every node; we keep the arrays whose final path
# element is "resources", which matches root_module.resources and any nested
# module_calls[...].module.resources. This is why a module-wrapped bucket is not
# silently missed.
config_resources contains r if {
	walk(input.configuration, [path, value])
	path[count(path) - 1] == "resources"
	some r in value
}

# SC-28: an aws_s3_bucket with no server-side encryption configuration that
# references it is denied. We match by reference, not by value: at plan time the
# bucket's final name is unknown (random suffix), but the encryption resource
# records a static reference to the bucket's address in
# .expressions.bucket.references (e.g. "aws_s3_bucket.primary.id").
deny contains msg if {
	some bucket in config_resources
	bucket.type == bucket_type
	bucket_addr := sprintf("aws_s3_bucket.%s", [bucket.name])
	not encryption_references(bucket_addr)

	msg := sprintf(
		"SC-28: aws_s3_bucket '%s' has no matching server-side encryption configuration. Remediation: add an aws_s3_bucket_server_side_encryption_configuration that references it.",
		[bucket.name],
	)
}

# True if some encryption resource references this bucket's address.
encryption_references(bucket_addr) if {
	some r in config_resources
	r.type == sse_type
	some ref in r.expressions.bucket.references
	references_bucket(ref, bucket_addr)
}

# A reference matches the bucket by its bare address ("aws_s3_bucket.primary")
# or any attribute of it ("aws_s3_bucket.primary.id", ".arn", ...).
references_bucket(ref, bucket_addr) if ref == bucket_addr

references_bucket(ref, bucket_addr) if startswith(ref, sprintf("%s.", [bucket_addr]))
