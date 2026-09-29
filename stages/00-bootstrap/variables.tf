variable "region" {
  description = "Home region for everything in this project."
  type        = string
  default     = "eu-west-3"
}

variable "management_account_id" {
  description = <<-EOT
    The management account's 12-digit ID. The provider refuses to run against
    any other account (see allowed_account_ids in versions.tf).

    Kept in the gitignored terraform.tfvars so the public repo doesn't carry it.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be exactly 12 digits."
  }
}

# The GitHub repo whose workflows may assume the CI roles (ci-identity.tf).
# The numeric IDs are public (api.github.com/repos/<owner>/<repo>) and are what
# make the trust policy survive a rename or a lookalike repo; see ci-identity.tf.
variable "github_owner" {
  description = "GitHub user or org that owns the repo."
  type        = string
  default     = "maws777"
}

variable "github_owner_id" {
  description = "Numeric ID of github_owner, as embedded in immutable OIDC subject claims."
  type        = string
  default     = "163140591"
}

variable "github_repository" {
  description = "Repository name, without the owner."
  type        = string
  default     = "landing-zone"
}

variable "github_repository_id" {
  description = "Numeric ID of the repository, as embedded in immutable OIDC subject claims."
  type        = string
  default     = "1386363061"
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
