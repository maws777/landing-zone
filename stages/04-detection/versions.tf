terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

# Management account: only used to read the organization (account IDs, org
# ID). Nothing is created here.
provider "aws" {
  region = var.region

  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
      stage        = "04-detection"
    }
  }
}

# security account: the detection stack.
#
# Two ways in, set by variables (exactly one; see variables.tf):
#   CI plan   -> job credentials + assume ci/landing-zone-ci-detect-plan
#   CI apply  -> job credentials + assume ci/landing-zone-ci-detect-apply
#   locally   -> profile security-admin (Identity Center, MFA)
# The CI roles are created in 00-bootstrap (security-access.tf). Same pattern
# as 03-dns.
provider "aws" {
  alias   = "security"
  region  = var.region
  profile = var.security_profile

  dynamic "assume_role" {
    for_each = var.security_role_name == null ? [] : [var.security_role_name]
    content {
      role_arn     = "arn:aws:iam::${local.security_account_id}:role/${assume_role.value}"
      session_name = "terraform-04-detection"
    }
  }

  allowed_account_ids = [local.security_account_id]

  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
      stage        = "04-detection"
    }
  }
}
