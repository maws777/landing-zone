# The remediation Lambda, its findings table and the alert topic.

# --- Findings: one item per event, written once -------------------------------

# Also the idempotency record: EventBridge delivers at least once, so the
# Lambda writes the finding with a "doesn't exist yet" condition and stops if
# it already does. Findings are kept 90 days (TTL), then DynamoDB deletes them.
resource "aws_dynamodb_table" "findings" {
  provider     = aws.security
  name         = "lz-findings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  deletion_protection_enabled = true
}

# --- Alerts: email, security alerts only (ADR 0016) ----------------------------

resource "aws_sns_topic" "alerts" {
  provider = aws.security
  name     = "lz-security-alerts"
}

# AWS emails a confirmation link first; nothing is delivered until it's
# clicked. The address is a sensitive variable (public repository).
resource "aws_sns_topic_subscription" "email" {
  provider  = aws.security
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- The Lambda ---------------------------------------------------------------

data "archive_file" "remediate" {
  type             = "zip"
  source_file      = "${path.module}/lambda/remediate.py"
  output_path      = "${path.module}/build/remediate.zip"
  output_file_mode = "0644"
}

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "remediate" {
  provider             = aws.security
  name                 = "lz-remediate"
  path                 = "/lz/"
  assume_role_policy   = data.aws_iam_policy_document.assume_lambda.json
  permissions_boundary = "arn:aws:iam::${local.security_account_id}:policy/platform/lz-detection-boundary"
}

data "aws_iam_policy_document" "remediate" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.remediate.arn}:*"]
  }
  statement {
    sid       = "Findings"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.findings.arn]
  }
  statement {
    sid       = "Alert"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
  # Into each member account's lz-remediation role (StackSet), which can only
  # do the two reverts. aws:ResourceOrgID: never a role outside this
  # organization, whatever it's called.
  statement {
    sid       = "AssumeRemediationRoles"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::*:role/lz/lz-remediation"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceOrgID"
      values   = [local.org_id]
    }
  }
}

resource "aws_iam_role_policy" "remediate" {
  provider = aws.security
  name     = "runtime"
  role     = aws_iam_role.remediate.id
  policy   = data.aws_iam_policy_document.remediate.json
}

resource "aws_cloudwatch_log_group" "remediate" {
  provider          = aws.security
  name              = "/aws/lambda/lz-remediate"
  retention_in_days = 90
}

resource "aws_lambda_function" "remediate" {
  provider         = aws.security
  function_name    = "lz-remediate"
  role             = aws_iam_role.remediate.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "remediate.handler"
  filename         = data.archive_file.remediate.output_path
  source_code_hash = data.archive_file.remediate.output_base64sha256
  memory_size      = 256
  timeout          = 30

  environment {
    variables = {
      FINDINGS_TABLE   = aws_dynamodb_table.findings.name
      ALERT_TOPIC_ARN  = aws_sns_topic.alerts.arn
      REMEDIATION_ROLE = "lz/lz-remediation"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.remediate.name
  }

  depends_on = [aws_iam_role_policy.remediate]
}
