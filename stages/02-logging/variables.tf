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

# How the log-archive provider gets in (versions.tf). Exactly one is set.
variable "log_archive_role_name" {
  description = <<-EOT
    Role (with its path) assumed in log-archive, from the job's credentials.
    CI sets it per job: ci/landing-zone-ci-logging-plan or
    ci/landing-zone-ci-logging-apply. Unset locally.
  EOT
  type        = string
  default     = null

  validation {
    # A conditional, not ||: Terraform evaluates both sides of ||, and
    # contains() on null would fail.
    condition = var.log_archive_role_name == null ? true : contains([
      "ci/landing-zone-ci-logging-plan",
      "ci/landing-zone-ci-logging-apply",
    ], var.log_archive_role_name)
    error_message = "log_archive_role_name must be one of the two CI logging roles."
  }
}

variable "log_archive_profile" {
  description = <<-EOT
    Locally: the Identity Center profile for log-archive (log-archive-admin),
    in terraform.tfvars. Replaces OrganizationAccountAccessRole, which step 6
    locks (ADR 0010). Unset in CI.
  EOT
  type        = string
  default     = null

  validation {
    condition     = (var.log_archive_profile == null) != (var.log_archive_role_name == null)
    error_message = "Set exactly one of log_archive_profile (local runs) or log_archive_role_name (CI)."
  }
}

variable "log_retention_days" {
  description = "Object Lock default retention (governance mode) for every log file. ADR 0008: one year."
  type        = number
  default     = 365
}
