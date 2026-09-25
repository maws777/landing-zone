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
