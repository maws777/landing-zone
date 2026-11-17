variable "region" {
  description = "Home region for everything in this project."
  type        = string
  default     = "eu-west-3"
}

variable "management_account_id" {
  description = <<-EOT
    The management account's 12-digit ID; the provider refuses any other.
    Locally: gitignored terraform.tfvars. In CI: TF_VAR_management_account_id
    from the MANAGEMENT_ACCOUNT_ID repository variable.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be exactly 12 digits."
  }
}

# How the security provider gets in (versions.tf). Exactly one is set.
variable "security_role_name" {
  description = <<-EOT
    Role (with its path) assumed in security, from the job's credentials.
    CI sets it per job: ci/landing-zone-ci-detect-plan or
    ci/landing-zone-ci-detect-apply. Unset locally.
  EOT
  type        = string
  default     = null

  validation {
    condition = var.security_role_name == null ? true : contains([
      "ci/landing-zone-ci-detect-plan",
      "ci/landing-zone-ci-detect-apply",
    ], var.security_role_name)
    error_message = "security_role_name must be one of the two CI detection roles."
  }
}

variable "security_profile" {
  description = <<-EOT
    Locally: the Identity Center profile for security (security-admin), in
    terraform.tfvars. Unset in CI.
  EOT
  type        = string
  default     = null

  validation {
    condition     = (var.security_profile == null) != (var.security_role_name == null)
    error_message = "Set exactly one of security_profile (local runs) or security_role_name (CI)."
  }
}

variable "alert_email" {
  description = <<-EOT
    Where security alerts go (SNS email; AWS sends a confirmation link first).
    Locally: terraform.tfvars. In CI: TF_VAR_alert_email from the ALERT_EMAIL
    repository secret. Sensitive: the repository and its CI logs are public.
  EOT
  type        = string
  sensitive   = true

  # A missing secret reaches Terraform as "", not as unset: fail the plan
  # instead of subscribing nobody.
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address (is the ALERT_EMAIL secret set?)."
  }
}
