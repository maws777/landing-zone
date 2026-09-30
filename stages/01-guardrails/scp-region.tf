# SCP: nothing happens outside the home region.
#
# Why: data residency (everything stays in Paris), a smaller surface to watch,
# and cost. A resource started by mistake in another region is invisible from
# an eu-west-3 console and keeps billing until someone notices.
#
# How: deny every action whose aws:RequestedRegion isn't eu-west-3, EXCEPT the
# actions listed in not_actions. Those are global services (IAM, Organizations,
# Route 53, CloudFront, billing, ...). They have one endpoint, physically in
# us-east-1, so their requests carry aws:RequestedRegion = us-east-1 even when
# nothing is being created there. Without these exceptions, IAM itself would be
# denied in every member account.
#
# The list is copied from AWS's maintained Region deny control:
#   https://docs.aws.amazon.com/controltower/latest/controlreference/primary-region-deny-policy.html
# (as of 2026-09-30). Copied rather than hand-picked, because AWS keeps it in
# step with how each service routes its calls; guessing gets it wrong in ways
# that only show up as a confusing AccessDenied weeks later. When AWS updates
# it, update it here too.
#
# Known future exception: Bedrock embeddings (roadmap step 8), if the chosen
# model isn't served in eu-west-3. That would be a deliberate, documented
# addition, not a widening of this list.

locals {
  region_deny_exempt_actions = [
    "a4b:*",
    "access-analyzer:*",
    "account:*",
    "acm:*",
    "activate:*",
    "artifact:*",
    "aws-marketplace-management:*",
    "aws-marketplace:*",
    "aws-portal:*",
    "billing:*",
    "billingconductor:*",
    "budgets:*",
    "ce:*",
    "chatbot:*",
    "chime:*",
    "cloudfront:*",
    "cloudtrail:LookupEvents",
    "compute-optimizer:*",
    "config:*",
    "consoleapp:*",
    "consolidatedbilling:*",
    "cur:*",
    "datapipeline:GetAccountLimits",
    "devicefarm:*",
    "directconnect:*",
    "ec2:DescribeRegions",
    "ec2:DescribeTransitGateways",
    "ec2:DescribeVpnGateways",
    "ecr-public:*",
    "fms:*",
    "freetier:*",
    "globalaccelerator:*",
    "health:*",
    "iam:*",
    "importexport:*",
    "invoicing:*",
    "iq:*",
    "kms:*",
    "license-manager:ListReceivedLicenses",
    "lightsail:Get*",
    "mobileanalytics:*",
    "networkmanager:*",
    "notifications-contacts:*",
    "notifications:*",
    "organizations:*",
    "payments:*",
    "pricing:*",
    "quicksight:DescribeAccountSubscription",
    "resource-explorer-2:*",
    "route53-recovery-cluster:*",
    "route53-recovery-control-config:*",
    "route53-recovery-readiness:*",
    "route53:*",
    "route53domains:*",
    "s3:CreateMultiRegionAccessPoint",
    "s3:DeleteMultiRegionAccessPoint",
    "s3:DescribeMultiRegionAccessPointOperation",
    "s3:GetAccountPublicAccessBlock",
    "s3:GetBucketLocation",
    "s3:GetBucketPolicyStatus",
    "s3:GetBucketPublicAccessBlock",
    "s3:GetMultiRegionAccessPoint",
    "s3:GetMultiRegionAccessPointPolicy",
    "s3:GetMultiRegionAccessPointPolicyStatus",
    "s3:GetStorageLensConfiguration",
    "s3:GetStorageLensDashboard",
    "s3:ListAllMyBuckets",
    "s3:ListMultiRegionAccessPoints",
    "s3:ListStorageLensConfigurations",
    "s3:PutAccountPublicAccessBlock",
    "s3:PutMultiRegionAccessPointPolicy",
    "savingsplans:*",
    "shield:*",
    "sso:*",
    "sts:*",
    "support:*",
    "supportapp:*",
    "supportplans:*",
    "sustainability:*",
    "tag:GetResources",
    "tax:*",
    "trustedadvisor:*",
    "vendor-insights:ListEntitledSecurityProfiles",
    "waf-regional:*",
    "waf:*",
    "wafv2:*",
  ]
}

data "aws_iam_policy_document" "region" {
  statement {
    sid         = "DenyOutsideHomeRegion"
    effect      = "Deny"
    not_actions = local.region_deny_exempt_actions
    resources   = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}

resource "aws_organizations_policy" "region" {
  name        = "region-restriction"
  description = "Deny all actions outside ${var.region}, except global services. Managed by 01-guardrails."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.region.minified_json

  lifecycle {
    # This one is long enough that the 5,120-character SCP limit is worth
    # checking at plan time rather than finding out from an API error mid-apply.
    precondition {
      condition     = length(data.aws_iam_policy_document.region.minified_json) <= 5120
      error_message = "region-restriction SCP exceeds the 5,120-character limit."
    }
  }
}
