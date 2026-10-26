# CI/CD identity: GitHub Actions -> AWS through OIDC, no stored keys.
#
# These live in the bootstrap stage on purpose, and this stage never runs in
# CI (ADR 0004). A pipeline that could apply the stage defining its own roles
# could rewrite its own trust policy or permissions: privilege escalation with
# extra steps. Keeping them here means a human with an admin session and a
# locally reviewed plan is the only way these roles change.
#
# How a CI run gets credentials:
#   1. The job asks GitHub for an OIDC token (needs `id-token: write`).
#   2. GitHub signs a JWT whose claims describe the run: repo, event, branch,
#      environment. `sub` is the claim that matters here.
#   3. The job calls sts:AssumeRoleWithWebIdentity with that JWT.
#   4. STS checks the signature against the provider below, then checks the
#      claims against the role's trust policy. Match -> ~1h credentials.

# Tells IAM to trust tokens signed by GitHub's issuer. One per account, shared by
# every role that trusts GitHub.
#
# No thumbprint_list: AWS validates GitHub's certificate against its own trusted
# CA library for this issuer, so a pinned thumbprint would add nothing but a
# thing that breaks when GitHub rotates certificates.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # The token's `aud` claim. configure-aws-credentials requests this audience by
  # default; the trust policies check it too.
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # The prefix every `sub` claim from this repo starts with.
  #
  # Repos created after 2026-07-15 get *immutable* subject claims that embed the
  # numeric owner and repo IDs next to the names. If the repo were renamed or
  # deleted and someone recreated one with the same name, that repo would have
  # different IDs and could not assume these roles. The name alone would not
  # give that guarantee.
  github_sub_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}"
}

# Trust policy builder shared by both roles: same provider, same audience, a
# list of exact `sub` values.
data "aws_iam_policy_document" "github_trust" {
  for_each = {
    plan = [
      # Any pull request in this repo. PRs from forks never receive an OIDC
      # token, so this effectively means branches pushed by people with write
      # access.
      "${local.github_sub_prefix}:pull_request",

      # A push to main, in a job with no environment: the plan that runs right
      # after a merge, so the approver of the apply sees what they're approving.
      # Still the read-only role; main only takes merged PRs.
      "${local.github_sub_prefix}:ref:refs/heads/main",
    ]

    # Only jobs that declare `environment: management`. The environment is where
    # the gates live: a required reviewer, and deployments limited to `main`.
    # A workflow edited to skip the environment gets a different `sub` and is
    # refused here, so the gate can't be bypassed from the YAML alone.
    apply = ["${local.github_sub_prefix}:environment:management"]
  }

  statement {
    effect  = "Allow"
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

    # StringEquals, not StringLike: no wildcards anywhere in the subject.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "github" {
  for_each = data.aws_iam_policy_document.github_trust

  name               = "landing-zone-ci-${each.key}"
  path               = "/ci/"
  description        = "GitHub Actions ${each.key} role for ${var.github_owner}/${var.github_repository}. Managed by 00-bootstrap."
  assume_role_policy = each.value.json

  # One hour is AWS's default and plenty for a plan or apply of one stage.
  max_session_duration = 3600
}

# ---------------------------------------------------------------------------
# What each role may do in AWS. Starts with exactly what 01-guardrails (SCPs)
# needs, and grows one stage at a time. Deliberately absent from both:
#   - any iam:* action, so CI can't change its own roles or create new ones
#   - account creation, closure, moving, or leaving the organization
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ci_permissions" {
  for_each = toset(["plan", "apply"])

  # Reading the organization's structure and policies, enough to refresh state.
  statement {
    sid = "ReadOrganization"
    actions = [
      "organizations:Describe*",
      "organizations:List*",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "ManagePolicies"
      actions = [
        "organizations:CreatePolicy",
        "organizations:UpdatePolicy",
        "organizations:DeletePolicy",
        "organizations:AttachPolicy",
        "organizations:DetachPolicy",
        "organizations:TagResource",
        "organizations:UntagResource",
      ]
      resources = ["*"]
    }
  }

  # --- 02-logging (ADR 0008) ----------------------------------------------

  # The hop into log-archive (log-archive-access.tf). Each role may assume only
  # its own counterpart: plan can't borrow apply's powers over there.
  statement {
    sid       = "AssumeLogArchiveRole"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.log_archive_ci[each.key].arn]
  }

  # --- State in log-archive (ADR 0009) --------------------------------------

  # The backend's hop to the state bucket (state-log-archive.tf), again only
  # into the matching role.
  statement {
    sid       = "AssumeStateRole"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.la_state_ci[each.key].arn]
  }

  # Reading trails. DescribeTrails has no resource-level permissions, so "*".
  statement {
    sid = "ReadCloudTrail"
    actions = [
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetTrail",
      "cloudtrail:GetTrailStatus",
      "cloudtrail:GetEventSelectors",
      "cloudtrail:GetInsightSelectors",
      "cloudtrail:ListTags",
    ]
    resources = ["*"]
  }

  # CloudTrail checks the service-linked role exists when an organization trail
  # is created (iam:GetRole in AWS's documented minimum). Read-only, and scoped
  # to service-linked roles, so CI still can't see or touch its own roles.
  statement {
    sid       = "ReadServiceLinkedRoles"
    actions   = ["iam:GetRole"]
    resources = ["arn:aws:iam::${var.management_account_id}:role/aws-service-role/*"]
  }

  # Create and configure the one organization trail, by exact ARN.
  #
  # Deliberately absent: cloudtrail:StopLogging and cloudtrail:DeleteTrail. A
  # pipeline that can turn off the audit log is the first thing an attacker who
  # compromised it would use. Stopping or deleting the trail is a human,
  # local, deliberate act, and step 9 will alarm on it.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "ManageOrgTrail"
      actions = [
        "cloudtrail:CreateTrail",
        "cloudtrail:UpdateTrail",
        "cloudtrail:StartLogging",
        "cloudtrail:PutEventSelectors",
        "cloudtrail:PutInsightSelectors",
        "cloudtrail:AddTags",
        "cloudtrail:RemoveTags",
      ]
      resources = [local.trail_arn]
    }
  }
}

resource "aws_iam_role_policy" "ci_permissions" {
  for_each = data.aws_iam_policy_document.ci_permissions

  name   = "stage-permissions"
  role   = aws_iam_role.github[each.key].id
  policy = each.value.json
}
