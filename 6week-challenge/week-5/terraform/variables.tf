variable "region" {
  type        = string
  description = "Primary/home region for the trail and Security Hub."
  default     = "us-west-2"
}

variable "replica_region" {
  type        = string
  description = "Region that receives the cross-region replica of the log bucket."
  default     = "us-east-2"
}

variable "profile" {
  type        = string
  description = "AWS CLI profile to use. Must resolve to expected_account_id."
  default     = "default"
}

variable "project_name" {
  type        = string
  description = "Short identifier; part of bucket names and the Project tag."
  default     = "grc-week5"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name must be 3-21 lowercase alphanumerics or hyphens, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment; drives the Environment tag."
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "expected_account_id" {
  type        = string
  description = "Guard rail: apply refuses to run if credentials resolve elsewhere."
  default     = "232929535631"
}
