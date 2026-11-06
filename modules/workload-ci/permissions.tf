# What the app's CI roles may do in the workload account (ADR 0013).
#
# Plan reads configuration. Apply manages resources named mcp-* / mcp/* (the
# naming convention of ADR 0012). Both are denied user data: DynamoDB items,
# Cognito users, log lines.
#
# Scoping by name has gaps where AWS has no names to scope: API Gateway, ACM
# and Cognito use random IDs, so apply can manage any of those in the account.
# Accepted, because the account holds nothing but the apps.

locals {
  arn_prefix = {
    lambda = "arn:aws:lambda:${var.region}:${local.account_id}"
    logs   = "arn:aws:logs:${var.region}:${local.account_id}"
    ddb    = "arn:aws:dynamodb:${var.region}:${local.account_id}"
    iam    = "arn:aws:iam::${local.account_id}"
  }
}

data "aws_iam_policy_document" "ci" {
  for_each = toset(["plan", "apply"])

  # --- State -----------------------------------------------------------------

  statement {
    sid       = "ListState"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  # Plan reads state and takes the lock (use_lockfile writes and deletes a
  # .tflock object); only apply writes state itself.
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "LockState"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "WriteState"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.state.arn}/*/terraform.tfstate"]
    }
  }

  # --- The DNS hop ------------------------------------------------------------

  statement {
    sid       = "AssumeDnsRole"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.dns[each.key].arn]
  }

  # Without this, the apply role could create a role under /mcp/ that trusts
  # itself, assume it, and get that role's permissions (item access to the
  # tables, within the boundary). In the same account a trust policy that names
  # a principal is enough on its own, no identity-policy Allow needed, so the
  # only way to close it is an explicit Deny: the DNS role is the one role CI
  # may ever assume.
  statement {
    sid           = "NoOtherRoles"
    effect        = "Deny"
    actions       = ["sts:AssumeRole", "sts:TagSession"]
    not_resources = [aws_iam_role.dns[each.key].arn]
  }

  # --- Reading configuration (both roles) -------------------------------------

  # Describe/Get/List on the services the apps use. Data reads are excluded by
  # what is listed (no logs:Get*, no dynamodb:Get*) and by the Deny below.
  statement {
    sid = "ReadConfiguration"
    actions = [
      "acm:Describe*",
      "acm:Get*",
      "acm:List*",
      "apigateway:GET",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "cognito-idp:Describe*",
      "cognito-idp:Get*",
      "cognito-idp:List*",
      "dynamodb:Describe*",
      "dynamodb:List*",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:Describe*",
      "ecr:Get*",
      "ecr:List*",
      "iam:Get*",
      "iam:List*",
      "lambda:Get*",
      "lambda:List*",
      "logs:Describe*",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
    ]
    resources = ["*"]
  }

  # --- Never user data (both roles) -------------------------------------------

  # The pipeline creates the table, the user pool and the log groups; it never
  # reads or writes what's in them. Invoking the functions is denied too: CI
  # tests the app over HTTPS like a client would, with a token.
  #
  # Honest limit: apply deploys the app's code, and that code reads the data by
  # design. These denies stop direct access and accidents (a data source in the
  # app's Terraform, a log line in a plan); what code gets deployed is guarded
  # by review and, in prod, the approval gate.
  statement {
    sid    = "NoUserData"
    effect = "Deny"
    actions = [
      "cognito-idp:Admin*",
      "cognito-idp:ListUsers",
      "cognito-idp:ListUsersInGroup",
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:DeleteItem",
      "dynamodb:ExportTableToPointInTime",
      "dynamodb:GetItem",
      "dynamodb:GetRecords",
      "dynamodb:PartiQL*",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:UpdateItem",
      "lambda:InvokeFunction",
      "lambda:InvokeFunctionUrl",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
      "logs:GetLogRecord",
      "logs:GetQueryResults",
      "logs:StartLiveTail",
      "logs:StartQuery",
      "logs:Unmask",
    ]
    resources = ["*"]
  }

  # --- Managing the apps (apply only) -----------------------------------------

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "AppFunctions"
      actions   = ["lambda:*"]
      resources = ["${local.arn_prefix.lambda}:function:mcp-*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "AppTables"
      actions   = ["dynamodb:*"]
      resources = ["${local.arn_prefix.ddb}:table/mcp-*", "${local.arn_prefix.ddb}:table/mcp-*/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "AppImages"
      actions   = ["ecr:*"]
      resources = ["arn:aws:ecr:${var.region}:${local.account_id}:repository/mcp/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid     = "AppLogGroups"
      actions = ["logs:*"]
      resources = [
        "${local.arn_prefix.logs}:log-group:/aws/lambda/mcp-*",
        "${local.arn_prefix.logs}:log-group:/aws/lambda/mcp-*:*",
        "${local.arn_prefix.logs}:log-group:/mcp/*",
        "${local.arn_prefix.logs}:log-group:/mcp/*:*",
      ]
    }
  }

  # Account-level calls without a resource ARN: registry login, and the log
  # delivery setup API Gateway access logs need (AWS's documented list for
  # HTTP API logging).
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "AccountLevel"
      actions = [
        "ecr:GetAuthorizationToken",
        "logs:CreateLogDelivery",
        "logs:DeleteLogDelivery",
        "logs:GetLogDelivery",
        "logs:ListLogDeliveries",
        "logs:PutResourcePolicy",
        "logs:UpdateLogDelivery",
      ]
      resources = ["*"]
    }
  }

  # Random-ID services (see the top of this file).
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "RandomIdServices"
      actions = [
        "acm:*",
        "apigateway:DELETE",
        "apigateway:PATCH",
        "apigateway:POST",
        "apigateway:PUT",
        "cognito-idp:*",
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "AppAlarmsAndDashboards"
      actions = [
        "cloudwatch:DeleteAlarms",
        "cloudwatch:DeleteDashboards",
        "cloudwatch:PutDashboard",
        "cloudwatch:PutMetricAlarm",
        "cloudwatch:TagResource",
        "cloudwatch:UntagResource",
      ]
      resources = [
        "arn:aws:cloudwatch:${var.region}:${local.account_id}:alarm:mcp-*",
        "arn:aws:cloudwatch::${local.account_id}:dashboard/mcp-*",
      ]
    }
  }

  # --- IAM: only under /mcp/, only with the boundary (apply only) -------------

  # These actions support the iam:PermissionsBoundary condition key: the role
  # being created or changed must carry exactly our boundary.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "RolesWithBoundary"
      actions = [
        "iam:AttachRolePolicy",
        "iam:CreateRole",
        "iam:DeleteRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePermissionsBoundary",
        "iam:PutRolePolicy",
      ]
      resources = ["${local.arn_prefix.iam}:role/mcp/*"]

      condition {
        test     = "StringEquals"
        variable = "iam:PermissionsBoundary"
        values   = [local.boundary_arn]
      }
    }
  }

  # The rest of a role's life cycle. These don't support the boundary key, and
  # don't need it: none of them can change what the role is allowed to do.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "RoleLifecycle"
      actions = [
        "iam:DeleteRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:UpdateRole",
        "iam:UpdateRoleDescription",
      ]
      resources = ["${local.arn_prefix.iam}:role/mcp/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "AppPolicies"
      actions = [
        "iam:CreatePolicy",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicy",
        "iam:DeletePolicyVersion",
        "iam:SetDefaultPolicyVersion",
        "iam:TagPolicy",
        "iam:UntagPolicy",
      ]
      resources = ["${local.arn_prefix.iam}:policy/mcp/*"]
    }
  }

  # Handing a role to Lambda when creating a function, and only to Lambda.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "PassRolesToLambda"
      actions   = ["iam:PassRole"]
      resources = ["${local.arn_prefix.iam}:role/mcp/*"]

      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["lambda.amazonaws.com"]
      }
    }
  }

  # Belt and braces around the platform's own pieces. The Allows above never
  # reach them (wrong paths), but a later widening shouldn't be able to either.
  statement {
    sid    = "ProtectPlatform"
    effect = "Deny"
    actions = [
      "iam:Add*",
      "iam:Attach*",
      "iam:Create*",
      "iam:Delete*",
      "iam:Detach*",
      "iam:Put*",
      "iam:Remove*",
      "iam:Set*",
      "iam:Tag*",
      "iam:Untag*",
      "iam:Update*",
    ]
    resources = [
      "${local.arn_prefix.iam}:role/ci/*",
      "${local.arn_prefix.iam}:policy/platform/*",
      "${local.arn_prefix.iam}:oidc-provider/*",
    ]
  }

  # Removing the boundary from a role would lift the ceiling.
  statement {
    sid       = "KeepBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci" {
  for_each = data.aws_iam_policy_document.ci

  name   = "workload-permissions"
  role   = aws_iam_role.ci[each.key].id
  policy = each.value.json
}
