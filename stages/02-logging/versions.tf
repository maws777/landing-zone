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
# The same credentials as above, plus one sts:AssumeRole into log-archive
# before every call. Which role depends on who runs this:
#   CI plan   -> ci/landing-zone-ci-logging-plan   (read the bucket config)
#   CI apply  -> ci/landing-zone-ci-logging-apply  (manage the bucket config)
#   locally   -> OrganizationAccountAccessRole     (admin; the CI roles trust
#                                                   only the CI roles)
# All three are created or documented in 00-bootstrap (log-archive-access.tf).
#
# The account ID is looked up from the organization (organization.tf) instead of
# being one more variable to keep in sync. A provider can depend on a data
# source from another provider: Terraform reads the lookup first, then
# configures this provider with the result.
provider "aws" {
  alias  = "log_archive"
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${local.log_archive_account_id}:role/${var.log_archive_role_name}"
    session_name = "terraform-02-logging"
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
