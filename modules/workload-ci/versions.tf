terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"

      # Two accounts: the default `aws` is the workload account (staging, prod),
      # `aws.network` is where the DNS zone lives. The caller passes both.
      configuration_aliases = [aws.network]
    }
  }
}
