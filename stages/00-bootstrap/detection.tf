# Detection, per account (roadmap step 9, ADR 0016, docs/design/09-detection.md).
#
# The central part (bus, Lambda, findings, alerts) is stage 04-detection in the
# security account. What every account needs to plug into it:
#
#   member accounts -> a service-managed StackSet (templates/detection-member.yaml)
#                      targeted at the organization root, auto-deployed to new
#                      accounts; no OrganizationAccountAccessRole needed (ADR 0010)
#   management      -> plain Terraform below: StackSets never deploy to the
#                      management account, and it's the one place where
#                      Organizations events (SCP changes) happen
#
# Both forward the same short list of CloudTrail events to the bus. The region
# SCP lets the StackSet role deploy the us-east-1 copy (IAM events only exist
# there); the management account isn't bound by SCPs.

locals {
  detection_bus_arn  = "arn:aws:events:${var.region}:${local.security_account_id}:event-bus/lz-detection"
  remediate_role_arn = "arn:aws:iam::${local.security_account_id}:role/lz/lz-remediate"
  detection_regions  = [var.region, "us-east-1"]
  detection_event_names = [
    "DeletePublicAccessBlock",
    "PutBucketPublicAccessBlock",
    "PutBucketPolicy",
    "PutBucketAcl",
    "AuthorizeSecurityGroupIngress",
    "ModifySecurityGroupRules",
    "AttachRolePolicy",
    "AttachUserPolicy",
    "PutRolePolicy",
    "PutUserPolicy",
    "CreatePolicyVersion",
    "CreateRole",
    "StopLogging",
    "DeleteTrail",
    "UpdateTrail",
    "DetachPolicy",
    "DeletePolicy",
    "UpdatePolicy",
  ]
}

# --- Member accounts: the StackSet ------------------------------------------------

resource "aws_cloudformation_stack_set" "detection" {
  name             = "lz-detection-member"
  description      = "Forwarding rule and remediation role for the landing zone detection (ADR 0016). Managed by 00-bootstrap."
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  template_body    = file("${path.module}/templates/detection-member.yaml")

  parameters = {
    DetectionBusArn  = local.detection_bus_arn
    RemediateRoleArn = local.remediate_role_arn
    HomeRegion       = var.region
  }

  # New accounts get the stacks without a Terraform run; an account that
  # leaves the organization loses them.
  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  # One region at a time, home region first (the instances below): the roles
  # are created there and the us-east-1 rule points at them by name.
  operation_preferences {
    region_concurrency_type = "SEQUENTIAL"
    failure_tolerance_count = 0
    max_concurrent_count    = 3
  }

  lifecycle {
    # Set by AWS for service-managed StackSets; would otherwise show as a diff.
    ignore_changes = [administration_role_arn]
  }
}

resource "aws_cloudformation_stack_set_instance" "detection_home" {
  stack_set_name            = aws_cloudformation_stack_set.detection.name
  stack_set_instance_region = var.region

  deployment_targets {
    organizational_unit_ids = [aws_organizations_organization.this.roots[0].id]
  }
}

resource "aws_cloudformation_stack_set_instance" "detection_us_east_1" {
  stack_set_name            = aws_cloudformation_stack_set.detection.name
  stack_set_instance_region = "us-east-1"

  deployment_targets {
    organizational_unit_ids = [aws_organizations_organization.this.roots[0].id]
  }

  depends_on = [aws_cloudformation_stack_set_instance.detection_home]
}

# --- Management account: its own forwarding ---------------------------------------

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "detection_forwarder" {
  name               = "lz-detection-forwarder"
  path               = "/lz/"
  description        = "Lets EventBridge forward the management account's risky API calls to the detection bus (ADR 0016). Managed by 00-bootstrap."
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "detection_forwarder" {
  name = "put-on-detection-bus"
  role = aws_iam_role.detection_forwarder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = local.detection_bus_arn
    }]
  })
}

locals {
  detection_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    source        = ["aws.s3", "aws.ec2", "aws.iam", "aws.cloudtrail", "aws.organizations"]
    detail        = { eventName = local.detection_event_names }
  })
}

# Home region: CloudTrail, S3, EC2 events.
resource "aws_cloudwatch_event_rule" "detection_forward" {
  name          = "lz-detect-forward"
  description   = "Risky API calls, forwarded to the security account (ADR 0016)."
  event_pattern = local.detection_pattern
}

resource "aws_cloudwatch_event_target" "detection_forward" {
  rule     = aws_cloudwatch_event_rule.detection_forward.name
  arn      = local.detection_bus_arn
  role_arn = aws_iam_role.detection_forwarder.arn
}

# us-east-1: IAM and Organizations (SCP changes) events, global services.
resource "aws_cloudwatch_event_rule" "detection_forward_us_east_1" {
  provider      = aws.us_east_1
  name          = "lz-detect-forward"
  description   = "Risky API calls, forwarded to the security account (ADR 0016)."
  event_pattern = local.detection_pattern
}

resource "aws_cloudwatch_event_target" "detection_forward_us_east_1" {
  provider = aws.us_east_1
  rule     = aws_cloudwatch_event_rule.detection_forward_us_east_1.name
  arn      = local.detection_bus_arn
  role_arn = aws_iam_role.detection_forwarder.arn
}

data "aws_caller_identity" "current" {}
