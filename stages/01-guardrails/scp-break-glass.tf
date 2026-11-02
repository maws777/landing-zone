# SCP: lock OrganizationAccountAccessRole ("break glass"), roadmap step 6, ADR 0010.
#
# Organizations creates this role in every account it creates: AdministratorAccess,
# trusting the whole management account. Anyone in management allowed
# sts:AssumeRole is admin everywhere, without MFA or Identity Center. Since step 6
# part A nothing uses it; Identity Center profiles replace it.
#
# Why an SCP and not deleting the role: the role keeps existing and can still be
# assumed (AssumeRole is called by a principal in management, which SCPs don't
# bind), but every action it then takes in the member account is denied. To break
# the glass in an emergency, detach this policy from the management account and
# the role works again. That detach is a CloudTrail event step 9 can alarm on.
#
# aws:PrincipalArn is the role's ARN (arn:aws:iam::<account>:role/<name>), not the
# session ARN, so the session name the caller picks doesn't matter. The account is
# a wildcard so new accounts are covered without a change.
#
# Rollout (ADR 0006 pattern): standalone policy on the Sandbox OU first, tested,
# then this statement moves into baseline-protections and this policy is deleted.

data "aws_iam_policy_document" "break_glass" {
  statement {
    sid       = "DenyOrganizationAccountAccessRole"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::*:role/OrganizationAccountAccessRole"]
    }
  }
}

resource "aws_organizations_policy" "break_glass" {
  name        = "lock-organization-access-role"
  description = "Deny every action to OrganizationAccountAccessRole (break glass: detach to restore). Managed by 01-guardrails."
  type        = "SERVICE_CONTROL_POLICY"

  content = data.aws_iam_policy_document.break_glass.minified_json
}
