# CI access to the security account (roadmap step 9, docs/design/09-detection.md).
#
# 04-detection builds the central detection pieces in security: the event
# bus every account forwards risky API calls to, the remediation Lambda, the
# findings table and the alert topic. It runs in CI, so CI needs a way in.
# Same two-key pattern as network (network-access.tf):
#
#   GitHub OIDC -> landing-zone-ci-{plan,apply}       (management)
#               -> sts:AssumeRole
#               -> landing-zone-ci-detect-{plan,apply} (security)
#
# Everything 04-detection creates is named lz-*; its runtime roles live under
# /lz/ and must carry the boundary below, so "may create roles" can't turn into
# "may become admin" in the security account (same reasoning as ADR 0013).

locals {
  security_account_id = aws_organizations_account.member["security"].id
  detect_boundary_arn = "arn:aws:iam::${local.security_account_id}:policy/platform/lz-detection-boundary"

  detect_arn = {
    events = "arn:aws:events:${var.region}:${local.security_account_id}"
    lambda = "arn:aws:lambda:${var.region}:${local.security_account_id}"
    ddb    = "arn:aws:dynamodb:${var.region}:${local.security_account_id}"
    sns    = "arn:aws:sns:${var.region}:${local.security_account_id}"
    logs   = "arn:aws:logs:${var.region}:${local.security_account_id}"
    iam    = "arn:aws:iam::${local.security_account_id}"
  }
}

resource "aws_iam_role" "security_detect_ci" {
  provider = aws.security
  for_each = data.aws_iam_policy_document.log_archive_trust

  name                 = "landing-zone-ci-detect-${each.key}"
  path                 = "/ci/"
  description          = "Assumed by the management CI ${each.key} role to manage the detection stack (step 9). Managed by 00-bootstrap."
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "security_detect_ci" {
  for_each = toset(["plan", "apply"])

  # Plan: read the configuration of what the stage manages.
  statement {
    sid = "ReadConfiguration"
    actions = [
      "events:Describe*",
      "events:List*",
      "lambda:Get*",
      "lambda:List*",
      "dynamodb:Describe*",
      "dynamodb:List*",
      "sns:Get*",
      "sns:List*",
      "iam:Get*",
      "iam:List*",
      "logs:Describe*",
      "logs:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # Apply: the stage's own resources, by name.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid     = "DetectionResources"
      actions = ["events:*", "lambda:*", "dynamodb:*", "sns:*", "logs:*"]
      resources = [
        "${local.detect_arn.events}:event-bus/lz-*",
        "${local.detect_arn.events}:rule/lz-*",
        "${local.detect_arn.events}:rule/lz-*/*",
        "${local.detect_arn.lambda}:function:lz-*",
        "${local.detect_arn.ddb}:table/lz-*",
        "${local.detect_arn.sns}:lz-*",
        "${local.detect_arn.logs}:log-group:/aws/lambda/lz-*",
        "${local.detect_arn.logs}:log-group:/aws/lambda/lz-*:*",
      ]
    }
  }

  # Roles only under /lz/, and only with the boundary. Without the condition,
  # CI could create a role with AdministratorAccess and hand it to a Lambda.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "RolesWithBoundary"
      actions = [
        "iam:CreateRole",
        "iam:PutRolePolicy",
        "iam:AttachRolePolicy",
        "iam:PutRolePermissionsBoundary",
      ]
      resources = ["${local.detect_arn.iam}:role/lz/*"]
      condition {
        test     = "StringEquals"
        variable = "iam:PermissionsBoundary"
        values   = [local.detect_boundary_arn]
      }
    }
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "RoleLifecycle"
      actions = [
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:DetachRolePolicy",
        "iam:UpdateAssumeRolePolicy",
        "iam:UpdateRole",
        "iam:UpdateRoleDescription",
        "iam:TagRole",
        "iam:UntagRole",
      ]
      resources = ["${local.detect_arn.iam}:role/lz/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "PassRolesToLambdaAndEvents"
      actions   = ["iam:PassRole"]
      resources = ["${local.detect_arn.iam}:role/lz/*"]
      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["lambda.amazonaws.com", "events.amazonaws.com"]
      }
    }
  }

  # Explicit denies: survive any later widening of the allows.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "KeepBoundary"
      effect    = "Deny"
      actions   = ["iam:DeleteRolePermissionsBoundary"]
      resources = ["*"]
    }
  }

  # The pipeline manages the findings table, it doesn't read findings.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid    = "NoFindingData"
      effect = "Deny"
      actions = [
        "dynamodb:GetItem",
        "dynamodb:BatchGetItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:BatchWriteItem",
        "dynamodb:PartiQL*",
        "lambda:InvokeFunction",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "security_detect_ci" {
  provider = aws.security
  for_each = data.aws_iam_policy_document.security_detect_ci

  name   = "detection"
  role   = aws_iam_role.security_detect_ci[each.key].id
  policy = each.value.json
}

# The ceiling for every role 04-detection creates. The remediation Lambda's
# role needs: its logs, the findings table, the alert topic, and assuming the
# lz-remediation role in member accounts of this organization (the StackSet
# deploys that role; its own policy limits what a revert may do).
data "aws_iam_policy_document" "detect_boundary" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.detect_arn.logs}:log-group:/aws/lambda/lz-*", "${local.detect_arn.logs}:log-group:/aws/lambda/lz-*:*"]
  }
  statement {
    sid       = "Findings"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
    resources = ["${local.detect_arn.ddb}:table/lz-*"]
  }
  statement {
    sid       = "Alerts"
    actions   = ["sns:Publish"]
    resources = ["${local.detect_arn.sns}:lz-*"]
  }
  statement {
    sid       = "Remediate"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::*:role/lz/lz-remediation"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceOrgID"
      values   = [aws_organizations_organization.this.id]
    }
  }
}

resource "aws_iam_policy" "detect_boundary" {
  provider    = aws.security
  name        = "lz-detection-boundary"
  path        = "/platform/"
  description = "Ceiling for every role 04-detection creates. Managed by landing-zone 00-bootstrap."
  policy      = data.aws_iam_policy_document.detect_boundary.json
}
