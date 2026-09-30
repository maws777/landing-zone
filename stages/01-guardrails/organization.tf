# Where SCPs attach: the organization root and the OUs under it.
#
# Looked up with data sources, not read from 00-bootstrap's state. CI is denied
# that state (it holds the account root emails, ADR 0004), and the OU IDs are
# no secret: the Organizations API hands them to anyone with List* rights.

data "aws_organizations_organization" "this" {}

data "aws_organizations_organizational_units" "top_level" {
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

locals {
  root_id = data.aws_organizations_organization.this.roots[0].id

  # OU name -> ID, e.g. { Sandbox = "ou-xxxx-yyyyyyyy", ... }. Names are the ones
  # 00-bootstrap creates; a typo in a lookup below fails the plan loudly
  # ("Invalid index") rather than attaching to the wrong place.
  ou_ids = { for ou in data.aws_organizations_organizational_units.top_level.children : ou.name => ou.id }
}
