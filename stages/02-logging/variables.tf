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

variable "log_archive_role_name" {
  description = <<-EOT
    Role (with its path) assumed in log-archive. CI sets it per job:
    ci/landing-zone-ci-logging-plan or ci/landing-zone-ci-logging-apply.
    Locally: OrganizationAccountAccessRole, in terraform.tfvars.
  EOT
  type        = string

  validation {
    condition = contains([
      "ci/landing-zone-ci-logging-plan",
      "ci/landing-zone-ci-logging-apply",
      "OrganizationAccountAccessRole",
    ], var.log_archive_role_name)
    error_message = "log_archive_role_name must be one of the two CI logging roles or OrganizationAccountAccessRole."
  }
}

variable "log_retention_days" {
  description = "Object Lock default retention (governance mode) for every log file. ADR 0008: one year."
  type        = number
  default     = 365
}
