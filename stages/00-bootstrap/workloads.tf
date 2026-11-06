# Workload accounts: what the MCP app repository deploys through (roadmap
# step 8, ADR 0012 and 0013).
#
# One module call per environment. It creates, in the workload account, a
# GitHub OIDC provider, the app's plan and apply CI roles, the permissions
# boundary every app role must carry and the app's state bucket; in network,
# the two DNS roles limited to that environment's names. All of it is IAM, so
# it lives here, applied locally, never by a pipeline (ADR 0004).
#
# Staging only for now. Prod is the same block with environment = "prod",
# patterns for *.lab.michaelteplov.com and the staging subtree denied.

# The zone 03-dns manages. Looked up, not referenced: bootstrap doesn't own it.
data "aws_route53_zone" "lab" {
  provider = aws.network

  name         = "lab.michaelteplov.com"
  private_zone = false
}

locals {
  mcp_sub_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.mcp_repository}@${var.mcp_repository_id}"
}

module "mcp_staging" {
  source = "../../modules/workload-ci"

  providers = {
    aws         = aws.staging
    aws.network = aws.network
  }

  environment       = "staging"
  region            = var.region
  github_sub_prefix = local.mcp_sub_prefix
  dns_zone_id       = data.aws_route53_zone.lab.zone_id

  # <app>.mcp.staging.lab..., <app>.staging.lab..., and their ACM validation
  # records. Not staging.lab.michaelteplov.com itself: the pattern needs a
  # label in front.
  dns_record_patterns = ["*.staging.lab.michaelteplov.com"]
}
