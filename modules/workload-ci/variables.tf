variable "environment" {
  description = "Workload environment, also the GitHub environment the apply role trusts (staging, prod)."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be staging or prod."
  }
}

variable "region" {
  description = "Home region; resource ARNs in the policies are built for it."
  type        = string
}

variable "github_sub_prefix" {
  description = <<-EOT
    Start of every OIDC `sub` claim from the app repository, with the immutable
    owner and repository IDs: repo:<owner>@<owner id>/<repo>@<repo id>.
  EOT
  type        = string

  validation {
    condition     = can(regex("^repo:[^@/]+@[0-9]+/[^@/]+@[0-9]+$", var.github_sub_prefix))
    error_message = "github_sub_prefix must look like repo:<owner>@<owner id>/<repo>@<repo id>."
  }
}

variable "dns_zone_id" {
  description = "ID of the lab.michaelteplov.com hosted zone in the network account."
  type        = string
}

variable "dns_record_patterns" {
  description = <<-EOT
    Record names the apply DNS role may create, change or delete, normalized
    the way Route 53 compares them (lowercase, no trailing dot). IAM wildcards:
    "*" matches any characters, dots included.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.dns_record_patterns) > 0 && alltrue([for p in var.dns_record_patterns : p == lower(p) && !endswith(p, ".")])
    error_message = "dns_record_patterns must be lowercase names without a trailing dot."
  }
}

variable "dns_record_denied_patterns" {
  description = "Names the apply DNS role may never change even if they match dns_record_patterns (prod: the staging subtree)."
  type        = list(string)
  default     = []
}
