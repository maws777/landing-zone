# CI access to the network account (roadmap step 7).
#
# 03-dns creates the Route 53 hosted zone for lab.michaelteplov.com inside the
# network account, and it runs in CI. Same two-key pattern as log-archive
# (log-archive-access.tf):
#
#   GitHub OIDC -> landing-zone-ci-{plan,apply}       (management)
#               -> sts:AssumeRole
#               -> landing-zone-ci-dns-{plan,apply}   (network)
#
# The management role needs sts:AssumeRole on the target (ci-identity.tf), and
# the target's trust policy names that exact role (log_archive_trust, reused
# below: it trusts the matching management CI role and nothing else, which is
# what this account needs too). OrganizationAccountAccessRole is locked
# (ADR 0010), so this is the only way CI gets into network.

resource "aws_iam_role" "network_dns_ci" {
  provider = aws.network
  for_each = data.aws_iam_policy_document.log_archive_trust

  name                 = "landing-zone-ci-dns-${each.key}"
  path                 = "/ci/"
  description          = "Assumed by the management CI ${each.key} role to manage Route 53 hosted zones. Managed by 00-bootstrap."
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

# What each role may do: Route 53 hosted zones and records, nothing else.
#
# Route 53 is a global service: its ARNs have no region or account
# (arn:aws:route53:::hostedzone/<id>), and these roles live in network, so
# "hostedzone/*" only ever means this account's zones. A zone's ID doesn't
# exist before it's created, so the ARNs can't be narrower than that.
data "aws_iam_policy_document" "network_dns_ci" {
  for_each = toset(["plan", "apply"])

  # Plan: read zones, records, tags and change status. DNS configuration is
  # public by nature (anyone can query the records), so reading it is harmless.
  statement {
    sid       = "ReadRoute53"
    actions   = ["route53:Get*", "route53:List*"]
    resources = ["*"]
  }

  # CreateHostedZone has no resource-level permissions (the zone doesn't exist
  # yet), so "*" is the only option AWS allows.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "CreateHostedZone"
      actions   = ["route53:CreateHostedZone"]
      resources = ["*"]
    }
  }

  # Configure existing zones: comment, tags, and records (step 8 adds the app's
  # records and the ACM validation records here).
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid = "ManageHostedZones"
      actions = [
        "route53:UpdateHostedZoneComment",
        "route53:ChangeTagsForResource",
        "route53:ChangeResourceRecordSets",
      ]
      resources = ["arn:aws:route53:::hostedzone/*"]
    }
  }

  # Deleting a zone is never a pipeline job. A new zone gets new name servers,
  # so the delegation at GoDaddy would have to be redone by hand. The explicit
  # Deny survives any later widening of the Allows above.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "NeverDeleteHostedZone"
      effect    = "Deny"
      actions   = ["route53:DeleteHostedZone"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "network_dns_ci" {
  provider = aws.network
  for_each = data.aws_iam_policy_document.network_dns_ci

  name   = "route53"
  role   = aws_iam_role.network_dns_ci[each.key].id
  policy = each.value.json
}
