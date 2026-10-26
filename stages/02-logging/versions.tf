terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Management account: the organization trail lives here (ADR 0008), because
# only the management account can create a trail that covers every account.
provider "aws" {
  region = var.region

  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
      stage        = "02-logging"
    }
  }
}

# log-archive account: the bucket the trail delivers to.
#
# Two ways in, set by variables (exactly one; see variables.tf):
#   CI plan   -> job credentials + assume ci/landing-zone-ci-logging-plan
#   CI apply  -> job credentials + assume ci/landing-zone-ci-logging-apply
#   locally   -> profile log-archive-admin (Identity Center, MFA)
# The CI roles are created in 00-bootstrap (log-archive-access.tf) and trust
# only the CI roles. Local runs used OrganizationAccountAccessRole until step
# 6 locked it (ADR 0010).
#
# The account ID is looked up from the organization (organization.tf) instead of
# being one more variable to keep in sync. A provider can depend on a data
# source from another provider: Terraform reads the lookup first, then
# configures this provider with the result.
provider "aws" {
  alias   = "log_archive"
  region  = var.region
  profile = var.log_archive_profile

  # A dynamic block: present in CI, absent locally, where the profile already
  # lands in log-archive.
  dynamic "assume_role" {
    for_each = var.log_archive_role_name == null ? [] : [var.log_archive_role_name]
    content {
      role_arn     = "arn:aws:iam::${local.log_archive_account_id}:role/${assume_role.value}"
      session_name = "terraform-02-logging"
    }
  }

  allowed_account_ids = [local.log_archive_account_id]

  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
      stage        = "02-logging"
    }
  }
}
