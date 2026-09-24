# Identity Center assignments for the new accounts.
#
# The instance, the group and the permission set were all created by hand on
# Day 0. They are looked up rather than declared: this stage only adds the
# assignments that connect them to the accounts it creates.
#
# Looking them up also keeps instance ARNs and identity store IDs out of the
# repo, which matters because this repo is public.

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn   = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  sso_identity_store = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

# The admins group. Permissions attach to groups, never to users directly, so
# granting someone access later is a membership change rather than a policy
# change.
data "aws_identitystore_group" "admins" {
  identity_store_id = local.sso_identity_store

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "admins"
    }
  }
}

# The existing AdministratorAccess permission set, looked up by name. Confirmed
# to exist with an 8-hour session duration; it was created on Day 0.
data "aws_ssoadmin_permission_set" "administrator" {
  instance_arn = local.sso_instance_arn
  name         = "AdministratorAccess"
}

# One assignment per account.
#
# What this actually does: for each account, Identity Center creates an IAM role
# named AWSReservedSSO_AdministratorAccess_<generated suffix> inside that
# account, carrying the permission set's policies and trusting Identity Center.
# Signing in through the portal is Identity Center assuming that role and
# handing back temporary credentials.
#
# Two things follow from that. Editing the permission set rewrites the role in
# every account it is assigned to. And the suffix is generated, so anything that
# needs to reference the role should match a prefix rather than a literal name.
resource "aws_ssoadmin_account_assignment" "admins" {
  for_each = aws_organizations_account.member

  instance_arn       = local.sso_instance_arn
  permission_set_arn = data.aws_ssoadmin_permission_set.administrator.arn

  principal_id   = data.aws_identitystore_group.admins.group_id
  principal_type = "GROUP"

  target_id   = each.value.id
  target_type = "AWS_ACCOUNT"
}
