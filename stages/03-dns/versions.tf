terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Management account: only used to look up the network account's ID from the
# organization (organization.tf). Nothing is created here.
provider "aws" {
  region = var.region

  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
      stage        = "03-dns"
    }
  }
}

# network account: the hosted zone.
#
# Two ways in, set by variables (exactly one; see variables.tf):
#   CI plan   -> job credentials + assume ci/landing-zone-ci-dns-plan
#   CI apply  -> job credentials + assume ci/landing-zone-ci-dns-apply
#   locally   -> profile network-admin (Identity Center, MFA)
# The CI roles are created in 00-bootstrap (network-access.tf) and trust only
# the matching management CI role. Same pattern as 02-logging.
provider "aws" {
  alias   = "network"
  region  = var.region
  profile = var.network_profile

  dynamic "assume_role" {
    for_each = var.network_role_name == null ? [] : [var.network_role_name]
    content {
      role_arn     = "arn:aws:iam::${local.network_account_id}:role/${assume_role.value}"
      session_name = "terraform-03-dns"
    }
  }

  allowed_account_ids = [local.network_account_id]

  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
      stage        = "03-dns"
    }
  }
}
