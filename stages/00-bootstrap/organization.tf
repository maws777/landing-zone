# The organization itself, and the OU structure under it.
#
# The organization already exists - it was created by hand on Day 0 - so it is
# brought under Terraform with the import block in imports.tf rather than
# created here.

resource "aws_organizations_organization" "this" {
  # ALL features, not CONSOLIDATED_BILLING: this is what makes Service Control
  # Policies and trusted access possible. Changing this later needs every member
  # account to approve, so it is set correctly from the start.
  feature_set = "ALL"

  # CRITICAL, and the reason the import plan gets reviewed on its own:
  #
  # This attribute is the COMPLETE list of services allowed to operate across
  # the organization. Terraform sets it to exactly what is written here - so an
  # entry that is live in AWS but missing from this list gets DISABLED on apply.
  #
  # sso.amazonaws.com is already enabled (Identity Center was set up on Day 0).
  # Omitting it would disable Identity Center's trusted access and break the
  # only sign-in path into this organization. It stays.
  aws_service_access_principals = [
    "sso.amazonaws.com",        # IAM Identity Center - already enabled, must not be removed
    "cloudtrail.amazonaws.com", # org-wide CloudTrail trail, roadmap step 4
  ]

  # Same whole-list semantics. SCPs are the preventive half of the guardrails.
  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY",
  ]

  lifecycle {
    # Destroying an organization is not something to do by accident: it would
    # orphan every member account and take the SCPs with it.
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Organizational units
#
# OUs are the unit an SCP attaches to, so the structure is drawn around which
# accounts should share a policy - not around tidiness.
# ---------------------------------------------------------------------------

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id
}

# Deliberately relaxed later: the detective controls (EventBridge -> Lambda
# auto-remediation) need somewhere a risky change is actually allowed to happen,
# so there is something to detect and revert during a demo.
resource "aws_organizations_organizational_unit" "sandbox" {
  name      = "Sandbox"
  parent_id = aws_organizations_organization.this.roots[0].id
}
