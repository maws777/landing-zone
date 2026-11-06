# The app repository's way into this workload account (ADR 0013).
#
# Its own OIDC provider, so app CI goes straight into the workload account and
# never passes through management: the app pipeline and the landing-zone
# pipeline share no role and no trust.

data "aws_caller_identity" "this" {}

locals {
  account_id = data.aws_caller_identity.this.account_id
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    # Pull requests, and pushes to main in jobs with no environment (the plan
    # shown before an apply is approved).
    plan = [
      "${var.github_sub_prefix}:pull_request",
      "${var.github_sub_prefix}:ref:refs/heads/main",
    ]

    # Only jobs that declare `environment: <staging|prod>`. Which branches may
    # deploy there is the GitHub environment's setting (main only).
    apply = ["${var.github_sub_prefix}:environment:${var.environment}"]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals: no wildcard anywhere in the subject.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each = data.aws_iam_policy_document.trust

  name                 = "mcp-ci-${each.key}"
  path                 = "/ci/"
  description          = "GitHub Actions ${each.key} role for the MCP app repository (${var.environment}). Managed by landing-zone 00-bootstrap."
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}
