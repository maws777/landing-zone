# The network account's ID, looked up from the organization rather than read
# from 00-bootstrap's state (CI is denied that state, ADR 0004).

data "aws_organizations_organization" "this" {}

locals {
  # [0] rather than one(): if the account is ever renamed, the list is empty and
  # the plan fails with "Invalid index" instead of quietly using null.
  network_account_id = [
    for account in data.aws_organizations_organization.this.accounts : account.id
    if account.name == "network"
  ][0]
}
