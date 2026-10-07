# SCP: baseline protections every member account gets.
#
# How an SCP works, in one paragraph: it is a ceiling, not a grant. An action in
# a member account succeeds only if the caller's IAM policies allow it AND every
# SCP on the path root -> OU -> account allows it. The FullAWSAccess policy AWS
# attached at the root is what "allows" by default; the policies in this stage
# are Deny statements layered on top of it. FullAWSAccess must stay attached:
# without it, nothing in a member account can do anything at all.
#
# SCPs never apply to the management account. That is why the CI roles and the
# management-admin session keep working whatever is attached here, and why a
# broken SCP can always be fixed: the account that manages SCPs is outside them.

data "aws_iam_policy_document" "baseline" {
  # An account that leaves the organization walks away from every SCP, the org
  # CloudTrail trail and centralised access. The simplest escape hatch there is,
  # so it is closed first.
  statement {
    sid       = "DenyLeaveOrganization"
    effect    = "Deny"
    actions   = ["organizations:LeaveOrganization"]
    resources = ["*"]
  }

  # Closing an account from inside it. A closed account is suspended for 90 days
  # and only a few closures are allowed per rolling 30 days, so a mistake (or an
  # attacker) here is slow and expensive to undo. Closing stays possible from the
  # management account, which SCPs don't bind. This statement replaces the
  # hand-made Day 0 policy DenyLeaveAndCloseAccount (see the session log,
  # 2026-09-30), which is deleted once this one is live at the root.
  statement {
    sid       = "DenyCloseAccount"
    effect    = "Deny"
    actions   = ["account:CloseAccount"]
    resources = ["*"]
  }

  # The root user of a member account can do anything IAM can't stop, which is
  # why it should never be used. An SCP is one of the few things that does bind
  # root in a member account.
  #
  # The Null condition is what keeps roadmap step 3 working. Centralized root
  # access replaces root passwords/keys with short-lived sessions started from
  # the management account (sts:AssumeRoot). Those sessions carry the
  # aws:AssumedRoot key; long-term root credentials don't. So "aws:AssumedRoot is
  # absent" means "someone logged in with the root password or a root key", and
  # only that is denied. Pattern from AWS's documentation of aws:AssumedRoot.
  statement {
    sid       = "DenyRootUserLongTermCredentials"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::*:root"]
    }

    condition {
      test     = "Null"
      variable = "aws:AssumedRoot"
      values   = ["true"]
    }
  }
}

resource "aws_organizations_policy" "baseline" {
  name        = "baseline-protections"
  description = "Deny leaving the organization, closing accounts, and use of member-account root credentials. Managed by 01-guardrails."
  type        = "SERVICE_CONTROL_POLICY"

  # Minified: SCPs are capped at 5,120 characters and whitespace counts.
  content = data.aws_iam_policy_document.baseline.minified_json
}
