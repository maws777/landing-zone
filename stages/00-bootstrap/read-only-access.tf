# Read-only access through Identity Center (roadmap step 6, ADR 0010).
#
# Until now the only way into any account was AdministratorAccess. This adds a
# second, smaller key: a `readers` group with ViewOnlyAccess on every account,
# the operator (you) in it for day-to-day looking around, and a test user to
# prove from the outside what the group can and can't do.
#
# Unlike the Day 0 pieces (identity-center.tf), everything here is created by
# Terraform rather than looked up.

# ViewOnlyAccess, not ReadOnlyAccess. Both are AWS-managed job-function
# policies, and the difference is the point:
#   ReadOnlyAccess  can *read data*: s3:GetObject on every bucket (Terraform
#                   state with the root emails, every CloudTrail log file),
#                   secrets values, DynamoDB items.
#   ViewOnlyAccess  can *see that things exist and how they're configured*:
#                   list buckets, describe roles and policies, read SCPs. Not
#                   the contents.
# Auditing a setup needs the second. Reading the data needs a reason, and then
# an admin session.
resource "aws_ssoadmin_permission_set" "view_only" {
  instance_arn = local.sso_instance_arn
  name         = "ViewOnlyAccess"
  description  = "See resources and their configuration, not their data. Managed by 00-bootstrap."

  # How long a portal or CLI session lasts before signing in again. Same as
  # the Day 0 AdministratorAccess set.
  session_duration = "PT8H"
}

resource "aws_ssoadmin_managed_policy_attachment" "view_only" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.view_only.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}

resource "aws_identitystore_group" "readers" {
  identity_store_id = local.sso_identity_store
  display_name      = "readers"
  description       = "ViewOnlyAccess on every account. Managed by 00-bootstrap."
}

# A user that exists only to test the group from the outside. Created without
# a password: Identity Center doesn't email API-created users, so the first
# sign-in starts from the console (Users -> test-reader -> Reset password ->
# send an email). See the README.
resource "aws_identitystore_user" "test_reader" {
  identity_store_id = local.sso_identity_store

  user_name    = "test-reader"
  display_name = "Test Reader"

  name {
    given_name  = "Test"
    family_name = "Reader"
  }

  emails {
    value   = var.test_reader_email
    primary = true
  }
}

# The operator was created by hand on Day 0, so looked up like the admins group.
data "aws_identitystore_user" "operator" {
  identity_store_id = local.sso_identity_store

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.operator_user_name
    }
  }
}

resource "aws_identitystore_group_membership" "readers" {
  for_each = {
    operator    = data.aws_identitystore_user.operator.user_id
    test_reader = aws_identitystore_user.test_reader.user_id
  }

  identity_store_id = local.sso_identity_store
  group_id          = aws_identitystore_group.readers.group_id
  member_id         = each.value
}

# Every account, management included: seeing the organization's structure and
# the SCPs is only possible from there.
#
# As with admins, each assignment becomes an AWSReservedSSO_ViewOnlyAccess_*
# role inside that account.
resource "aws_ssoadmin_account_assignment" "readers" {
  for_each = merge(
    { for name, account in aws_organizations_account.member : name => account.id },
    { management = var.management_account_id },
  )

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.view_only.arn

  principal_id   = aws_identitystore_group.readers.group_id
  principal_type = "GROUP"

  target_id   = each.value
  target_type = "AWS_ACCOUNT"

  # Assigning provisions the permission set into the account as a role. If
  # that happened before the policy was attached, the first role would carry
  # no permissions until the next provisioning.
  depends_on = [aws_ssoadmin_managed_policy_attachment.view_only]
}
