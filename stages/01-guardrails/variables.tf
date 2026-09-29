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
