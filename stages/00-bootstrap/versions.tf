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

  # Applied to every resource that supports tags, so nothing has to remember.
  # Makes "what created this?" answerable in the console and in Cost Explorer.
  default_tags {
    tags = {
      project      = "landing-zone"
      "managed-by" = "terraform"
    }
  }
}
