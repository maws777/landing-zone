terraform {
  # 1.10 introduced native S3 state locking (use_lockfile), which is why this
  # stage needs no DynamoDB table for the backend.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to the current major. Minor and patch updates come in freely;
      # 7.0 will not, because a major version is where breaking changes land.
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Credentials come from the normal chain (AWS_PROFILE locally, OIDC env vars
  # in CI later). This doesn't choose them, it checks them: the provider calls
  # sts:GetCallerIdentity first and stops with "account ID not allowed" if the
  # credentials belong to any other account, before a single resource is read.
  # Without it, a stray [default] profile once sent this stage to the wrong
  # account and the failure looked like an import bug.
  allowed_account_ids = [var.management_account_id]

  # Applied to every resource that supports tags, so nothing has to remember.
  # Makes "what created this?" answerable in the console and in Cost Explorer.
  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
    }
  }
}

# A second provider, for resources that live inside the log-archive account
# (log-archive-access.tf, state-log-archive.tf).
#
# It signs in with its own Identity Center profile, log-archive-admin, instead
# of the default provider's credentials. Until step 6 it assumed
# OrganizationAccountAccessRole in log-archive, the admin role Organizations
# creates in every new account and that trusts the whole management account.
# Step 6 locks that role with an SCP (ADR 0010), so this stage enters
# log-archive the way a person does: through Identity Center, with MFA.
#
# The account ID comes from the account resource in this same stage. That works
# because the account already exists, so its ID is known at plan time. On an
# empty state the accounts would have to be applied first (-target), which is
# how this stage was built anyway.
provider "aws" {
  alias   = "log_archive"
  region  = var.region
  profile = var.log_archive_profile

  # Same safety check as the default provider: stop if the profile turns out
  # to point at any other account.
  allowed_account_ids = [aws_organizations_account.member["log-archive"].id]

  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
    }
  }
}
