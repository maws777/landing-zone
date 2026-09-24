# Bringing the existing organization under Terraform.
#
# The organization was created by hand on Day 0 (see docs/day0.md), because an
# organization has to exist before the Organizations API can be called at all.
# An import block adopts it into state instead of trying to create a second one,
# which would fail.
#
# Why an import block rather than `terraform import`: this is declarative and
# committed, so the plan shows the adoption before anything happens and the next
# person can see how state got its contents. The CLI command does it invisibly.
#
# The block can be deleted once the import has been applied. It is kept as a
# record of where the organization came from.
#
# ---------------------------------------------------------------------------
# WHAT TO WATCH FOR IN THE PLAN
#
# This import is the one genuinely dangerous step in the stage.
# aws_service_access_principals is a whole-list attribute, so anything enabled in
# AWS but absent from organization.tf gets DISABLED on apply.
#
# At time of writing, exactly one principal is enabled: sso.amazonaws.com.
# organization.tf lists that one plus cloudtrail.amazonaws.com.
#
# So the correct plan shows cloudtrail.amazonaws.com being ADDED and nothing
# being removed. If the plan proposes removing sso.amazonaws.com, stop: applying
# it would disable Identity Center trusted access and break the only sign-in
# path into this organization.
# ---------------------------------------------------------------------------

import {
  to = aws_organizations_organization.this

  # The organization ID. Not a secret - it appears in every SCP and role ARN in
  # the organization - but the account ID it belongs to is not in this repo.
  id = "o-zwsk12p8wd"
}
