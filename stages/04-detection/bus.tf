# The central detection bus (docs/design/09-detection.md, ADR 0016).
#
# Every account forwards the CloudTrail events of a short list of risky API
# calls here (the forwarding rules come with the StackSet, 00-bootstrap). One
# rule on this bus sends them all to the remediation Lambda.

resource "aws_cloudwatch_event_bus" "detection" {
  provider = aws.security
  name     = "lz-detection"
}

# Who may put events on the bus: any account of this organization, nobody
# else. The forwarding rules deliver with a role in the source account, so the
# principal is that account.
data "aws_iam_policy_document" "bus" {
  statement {
    sid       = "OrganizationAccountsMayForward"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.detection.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [local.org_id]
    }
  }
}

resource "aws_cloudwatch_event_bus_policy" "detection" {
  provider       = aws.security
  event_bus_name = aws_cloudwatch_event_bus.detection.name
  policy         = data.aws_iam_policy_document.bus.json
}

# The same list as the forwarding rules: anything else reaching the bus is
# ignored. Kept in one place (locals) so the StackSet template in 00-bootstrap
# can be compared with it.
locals {
  watched_events = {
    "aws.s3" = [
      "DeleteBucketPublicAccessBlock",
      "PutBucketPublicAccessBlock",
      "PutBucketPolicy",
      "PutBucketAcl",
    ]
    "aws.ec2" = [
      "AuthorizeSecurityGroupIngress",
      "ModifySecurityGroupRules",
    ]
    "aws.iam" = [
      "AttachRolePolicy",
      "AttachUserPolicy",
      "PutRolePolicy",
      "PutUserPolicy",
      "CreatePolicyVersion",
      "CreateRole",
    ]
    "aws.organizations" = [
      "DetachPolicy",
      "DeletePolicy",
      "UpdatePolicy",
    ]
    "aws.cloudtrail" = [
      "StopLogging",
      "DeleteTrail",
      "UpdateTrail",
    ]
  }
}

resource "aws_cloudwatch_event_rule" "to_remediate" {
  provider       = aws.security
  name           = "lz-to-remediate"
  description    = "Risky API calls forwarded from the organization's accounts."
  event_bus_name = aws_cloudwatch_event_bus.detection.name

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    source        = keys(local.watched_events)
    detail = {
      eventName = distinct(flatten(values(local.watched_events)))
    }
  })
}

resource "aws_cloudwatch_event_target" "remediate" {
  provider       = aws.security
  rule           = aws_cloudwatch_event_rule.to_remediate.name
  event_bus_name = aws_cloudwatch_event_bus.detection.name
  arn            = aws_lambda_function.remediate.arn

  retry_policy {
    maximum_retry_attempts       = 3
    maximum_event_age_in_seconds = 3600
  }
}

resource "aws_lambda_permission" "events" {
  provider      = aws.security
  statement_id  = "AllowDetectionBus"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediate.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.to_remediate.arn
}
