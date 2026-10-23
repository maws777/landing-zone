# Facts about the organization, looked up rather than read from 00-bootstrap's
# state (CI is denied that state, ADR 0004).

data "aws_organizations_organization" "this" {}

locals {
  organization_id = data.aws_organizations_organization.this.id

  # [0] rather than one(): if the account is ever renamed, the list is empty and
  # the plan fails with "Invalid index". one() would quietly return null.
  log_archive_account_id = [
    for account in data.aws_organizations_organization.this.accounts : account.id
    if account.name == "log-archive"
  ][0]

  # Both names are fixed by convention in 00-bootstrap (log-archive-access.tf
  # and ci-identity.tf), where the CI roles are scoped to them. Change them
  # here and CI loses access, so change them in both places or not at all.
  log_bucket_name = "landing-zone-org-trail-${local.log_archive_account_id}"
  trail_name      = "landing-zone-org-trail"

  # Built from parts, not read from the trail resource: the bucket policy must
  # name the trail before the trail exists (CloudTrail checks the policy when
  # the trail is created), so referencing aws_cloudtrail.org.arn would be a cycle.
  trail_arn = "arn:aws:cloudtrail:${var.region}:${var.management_account_id}:trail/${local.trail_name}"
}
