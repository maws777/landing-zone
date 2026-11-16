# The permissions boundary every role the app creates must carry (ADR 0013).
#
# Why it exists: the app's Terraform creates IAM roles (one per Lambda), and
# "may create roles" normally means "may become admin": create a role with
# AdministratorAccess, hand it to a Lambda, run code as it. A boundary is a
# ceiling on a role: an action is allowed only if the role's own policies AND
# the boundary allow it. The apply role (permissions.tf) may only create roles
# that carry this boundary, and may never remove it, so whatever policy the app
# attaches, its roles can't do more than what is listed here.
#
# It lives under /platform/, a path the apply role can't write to.
#
# This is the runtime ceiling for every MCP app: widening it (a new AWS service
# for an app) is a landing-zone PR, on purpose.

locals {
  boundary_name = "mcp-workload-boundary"
  boundary_arn  = "arn:aws:iam::${local.account_id}:policy/platform/${local.boundary_name}"
}

data "aws_iam_policy_document" "boundary" {
  # Lambda's own log groups.
  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/mcp-*",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/mcp-*:*",
    ]
  }

  # The apps' tables and their indexes, items included: this is what the
  # Lambdas are for. (The pipeline itself is denied item access, permissions.tf.)
  statement {
    sid = "AppTables"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:ConditionCheckItem",
    ]
    resources = [
      "arn:aws:dynamodb:${var.region}:${local.account_id}:table/mcp-*",
      "arn:aws:dynamodb:${var.region}:${local.account_id}:table/mcp-*/index/*",
    ]
  }

  # A schedule's role invoking its function (the nightly summary). Only the
  # apps' own functions.
  statement {
    sid       = "InvokeAppFunctions"
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:aws:lambda:${var.region}:${local.account_id}:function:mcp-*"]
  }

  # Tracing. X-Ray has no resource-level permissions for these.
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  # The dashboard's AI summaries (roadmap step 8). Which regions it reaches is
  # decided by the region SCP (ADR 0014).
  #
  # Haiku only: the ceiling is about cost as much as access. With "*" a role
  # under this boundary could call the most expensive model on Bedrock. A call
  # through an inference profile is authorized twice, on the profile (in this
  # account, home region) and on the foundation model in whichever region the
  # profile routes to (no account in that ARN), so both are listed.
  statement {
    sid = "Bedrock"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:aws:bedrock:${var.region}:${local.account_id}:inference-profile/eu.anthropic.claude-haiku-*",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-*",
    ]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = local.boundary_name
  path        = "/platform/"
  description = "Ceiling for every role the MCP app repository creates. Managed by landing-zone 00-bootstrap."
  policy      = data.aws_iam_policy_document.boundary.json
}
