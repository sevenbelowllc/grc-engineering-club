terraform {
  # Partial backend config. The bucket name is account-specific (and backend
  # blocks cannot interpolate variables), so bucket + region are supplied at
  # init time via -backend-config. See backend.hcl.example and the README.
  backend "s3" {
    key          = "week-1/solution/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # native S3 state locking (Terraform >= 1.10), no DynamoDB
  }
}
