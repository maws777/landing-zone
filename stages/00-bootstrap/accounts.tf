# Member accounts.
#
# APPLY THIS LAST, and only after confirming the list and the email addresses.
# Creating an account is instant; undoing it is not. Closing an AWS account puts
# it in a 90-day suspended state first, and the number of accounts that can be
# closed per rolling 30 days is a percentage of the accounts in the
# organization - with 7 accounts that is roughly one. A typo here is a problem
# measured in months.
#
# Quota check (2026-09-24): "Maximum number of accounts" (L-E619E033) is 10 and
# 1 was in use, so 6 new accounts lands at 7 of 10. Adjustable on request.
# Note the quota is only readable from us-east-1: Organizations is a global
# service and does not expose quotas in eu-west-3.

locals {
  # The account name -> OU mapping. Each account goes in the OU whose policy
  # boundary it should share.
  accounts = {
    # Security OU: the audit and log-retention accounts. Kept apart from
    # workloads so that someone who compromises an application cannot also
    # rewrite the evidence.
    "log-archive" = aws_organizations_organizational_unit.security.id
    "security"    = aws_organizations_organizational_unit.security.id

    # Infrastructure OU: shared plumbing, no application code.
    "network" = aws_organizations_organizational_unit.infrastructure.id

    # Workloads OU: the application environments. Separate accounts rather than
    # separate VPCs, so a mistake in staging cannot reach prod - the account is
    # the strongest boundary AWS has.
    "staging" = aws_organizations_organizational_unit.workloads.id
    "prod"    = aws_organizations_organizational_unit.workloads.id

    # Sandbox OU: intentionally loose SCPs later, so the detective controls have
    # something real to catch during a demo.
    "sandbox" = aws_organizations_organizational_unit.sandbox.id
  }
}

resource "aws_organizations_account" "member" {
  for_each = local.accounts

  name      = each.key
  email     = var.account_emails[each.key]
  parent_id = each.value

  # Lets IAM principals and Identity Center roles in this account read billing
  # data, the same setting that was flipped by hand on the management account.
  # Without it, billing pages are root-only.
  iam_user_access_to_billing = "ALLOW"

  # If this resource is ever removed from Terraform, the account is left alone
  # rather than closed. Removing it from state is recoverable; a closure is a
  # 90-day wait. Deliberate closures happen by hand, on purpose.
  close_on_deletion = false

  lifecycle {
    prevent_destroy = true

    # role_name cannot be read back through the Organizations API, so Terraform
    # sees it as absent on every refresh and would want to replace the account
    # to "fix" it. Replacing an account means closing one and creating another.
    # Ignoring it is what keeps a routine plan from proposing that.
    ignore_changes = [role_name]
  }
}

# ---------------------------------------------------------------------------
# OrganizationAccountAccessRole
#
# Creating an account this way also creates an IAM role called
# OrganizationAccountAccessRole inside it: AdministratorAccess, with a trust
# policy naming the management account. That is the bootstrap access path -
# without it a brand-new account has no way in except its root user.
#
# It is also a wide door: anyone who can assume roles from the management
# account gets full admin in every member account, and its use is only visible
# in CloudTrail rather than being gated by anything.
#
# Roadmap step 6 restricts it, once Identity Center provides a real access path
# to each account (identity-center.tf below) and locking it down cannot strand
# us. Until then it stays as the escape hatch.
# ---------------------------------------------------------------------------
