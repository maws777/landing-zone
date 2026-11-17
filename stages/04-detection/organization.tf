# The security account's ID and the organization ID, looked up from the
# organization rather than read from 00-bootstrap's state (CI is denied that
# state, ADR 0004).

data "aws_organizations_organization" "this" {}

locals {
  # [0] rather than one(): a renamed account fails the plan loudly.
  security_account_id = [
    for account in data.aws_organizations_organization.this.accounts : account.id
    if account.name == "security"
  ][0]

  org_id = data.aws_organizations_organization.this.id
}
