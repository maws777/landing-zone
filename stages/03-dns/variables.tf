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

# How the network provider gets in (versions.tf). Exactly one is set.
variable "network_role_name" {
  description = <<-EOT
    Role (with its path) assumed in network, from the job's credentials.
    CI sets it per job: ci/landing-zone-ci-dns-plan or
    ci/landing-zone-ci-dns-apply. Unset locally.
  EOT
  type        = string
  default     = null

  validation {
    condition = var.network_role_name == null ? true : contains([
      "ci/landing-zone-ci-dns-plan",
      "ci/landing-zone-ci-dns-apply",
    ], var.network_role_name)
    error_message = "network_role_name must be one of the two CI DNS roles."
  }
}

variable "network_profile" {
  description = <<-EOT
    Locally: the Identity Center profile for network (network-admin), in
    terraform.tfvars. Unset in CI.
  EOT
  type        = string
  default     = null

  validation {
    condition     = (var.network_profile == null) != (var.network_role_name == null)
    error_message = "Set exactly one of network_profile (local runs) or network_role_name (CI)."
  }
}

variable "zone_name" {
  description = "The subdomain delegated from GoDaddy to Route 53. The parent domain stays at GoDaddy."
  type        = string
  default     = "lab.michaelteplov.com"
}
