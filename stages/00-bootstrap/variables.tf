variable "region" {
  description = "Home region for everything in this project."
  type        = string
  default     = "eu-west-3"
}

variable "account_emails" {
  description = <<-EOT
    Root email address per member account, keyed by account name.

    These are the root user identities of real AWS accounts and cannot be
    changed casually, so they live in a gitignored terraform.tfvars. See
    terraform.tfvars.example for the pattern.

    Keys must match the account names used in accounts.tf.
  EOT
  type        = map(string)

  validation {
    condition = alltrue([
      for name in ["log-archive", "security", "network", "staging", "prod", "sandbox"] :
      contains(keys(var.account_emails), name)
    ])
    error_message = "account_emails must contain an entry for each of: log-archive, security, network, staging, prod, sandbox."
  }

  validation {
    # Catches the most likely typo: a duplicated address. AWS requires a unique
    # root email per account, so a duplicate fails mid-apply after some accounts
    # already exist - much more annoying than failing at plan time.
    condition     = length(values(var.account_emails)) == length(distinct(values(var.account_emails)))
    error_message = "Each account needs a unique root email address; found a duplicate."
  }
}
