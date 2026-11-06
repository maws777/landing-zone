# The app's DNS records, in the network account's zone (ADR 0013).
#
# Two roles in network, each trusted only by the matching CI role in the
# workload account (exact ARN). Same two-key pattern as the landing zone's own
# cross-account roles: the workload role needs sts:AssumeRole on the target
# (permissions.tf), and the target's trust names the caller (below).
#
# Apply may change only records whose names match dns_record_patterns. Route 53
# compares normalized names (lowercase, no trailing dot) and the key is
# multi-valued (one name per change in the batch), so ForAllValues: every name
# in the request must match. That covers the app's endpoints and their ACM
# validation records (_<token>.<name>), and nothing else in the zone: not its
# NS or SOA records, not the other environment's names.

data "aws_iam_policy_document" "dns_trust" {
  for_each = aws_iam_role.ci

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [each.value.arn]
    }
  }
}

resource "aws_iam_role" "dns" {
  provider = aws.network
  for_each = data.aws_iam_policy_document.dns_trust

  name                 = "mcp-dns-${var.environment}-${each.key}"
  path                 = "/ci/"
  description          = "Assumed by the MCP app's ${var.environment} ${each.key} CI role for its DNS records. Managed by landing-zone 00-bootstrap."
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "dns" {
  for_each = toset(["plan", "apply"])

  # Reading the zone, its records and change status. DNS is public anyway.
  statement {
    sid       = "ReadRoute53"
    actions   = ["route53:Get*", "route53:List*"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "OwnRecordsOnly"
      actions   = ["route53:ChangeResourceRecordSets"]
      resources = ["arn:aws:route53:::hostedzone/${var.dns_zone_id}"]

      condition {
        test     = "ForAllValues:StringLike"
        variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
        values   = var.dns_record_patterns
      }
    }
  }

  # Carve-outs (prod: the staging subtree, which its pattern would also match).
  dynamic "statement" {
    for_each = each.key == "apply" && length(var.dns_record_denied_patterns) > 0 ? [1] : []
    content {
      sid       = "NotTheseRecords"
      effect    = "Deny"
      actions   = ["route53:ChangeResourceRecordSets"]
      resources = ["*"]

      condition {
        test     = "ForAnyValue:StringLike"
        variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
        values   = var.dns_record_denied_patterns
      }
    }
  }
}

resource "aws_iam_role_policy" "dns" {
  provider = aws.network
  for_each = data.aws_iam_policy_document.dns

  name   = "route53-records"
  role   = aws_iam_role.dns[each.key].id
  policy = each.value.json
}
