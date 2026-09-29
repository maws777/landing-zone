terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Same check as 00-bootstrap: whatever the credentials are (a local SSO
  # profile, or the CI role from OIDC), refuse to run unless they belong to the
  # management account. SCPs can only be managed from there.
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
      stage        = "01-guardrails"
    }
  }
}
