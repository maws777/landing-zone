# CI access to the log-archive account (roadmap step 4, ADR 0008).
#
# The 02-logging stage creates the CloudTrail bucket inside log-archive, and it
# runs in CI. CI's roles live in the management account, so it needs a way into
# log-archive. Two options were on the table:
#
#   A. CI assumes OrganizationAccountAccessRole: full admin in the account that
#      holds the evidence, from a pipeline. Rejected.
#   B. This file: two roles inside log-archive that can only touch the log
#      bucket, each trusted only by the matching CI role in management.
#
# How a CI run reaches the bucket (role chaining):
#   GitHub OIDC -> landing-zone-ci-{plan,apply}           (management)
#               -> sts:AssumeRole
#               -> landing-zone-ci-logging-{plan,apply}   (log-archive)
#
# Both hops must agree: the management role needs sts:AssumeRole on the target
# (ci-identity.tf), and the target's trust policy must name the caller (below).
# Either side alone isn't enough, which is what makes it a two-key system.

locals {
  log_archive_account_id = aws_organizations_account.member["log-archive"].id

  # Fixed by convention so both stages agree without reading each other's state:
  # 02-logging builds the same name from its own provider's account ID. Bucket
  # names are global across all AWS accounts, so the account ID keeps it unique.
  log_bucket_name = "landing-zone-org-trail-${local.log_archive_account_id}"
  log_bucket_arn  = "arn:aws:s3:::${local.log_bucket_name}"

  # The organization trail lives in management (ADR 0008). Its ARN is
  # predictable, which lets permissions name it before it exists.
  trail_name = "landing-zone-org-trail"
  trail_arn  = "arn:aws:cloudtrail:${var.region}:${var.management_account_id}:trail/${local.trail_name}"
}

data "aws_iam_policy_document" "log_archive_trust" {
  for_each = aws_iam_role.github

  statement {
    actions = ["sts:AssumeRole"]

    # The exact role ARN, not the management account root. Naming the account
    # (arn:...:root) would let *any* principal in management that has
    # sts:AssumeRole in its own policy come in, including future roles.
    principals {
      type        = "AWS"
      identifiers = [each.value.arn]
    }
  }
}

resource "aws_iam_role" "log_archive_ci" {
  provider = aws.log_archive
  for_each = data.aws_iam_policy_document.log_archive_trust

  name                 = "landing-zone-ci-logging-${each.key}"
  path                 = "/ci/"
  description          = "Assumed by the management CI ${each.key} role to manage the CloudTrail bucket. Managed by 00-bootstrap."
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

# What each role may do: the log bucket and nothing else.
#
# Every Resource below is the *bucket* ARN, never "<bucket>/*". In S3, actions
# on objects (GetObject, DeleteObject, PutObjectRetention,
# BypassGovernanceRetention, ...) only match object ARNs. So even `s3:*` here
# cannot read, delete or unlock a single log file: it can only configure the
# bucket. Terraform never needs the objects, so CI never gets them.
data "aws_iam_policy_document" "log_archive_ci" {
  for_each = toset(["plan", "apply"])

  # Plan: read the bucket's configuration to compare it with the code.
  statement {
    sid       = "ReadLogBucketConfig"
    actions   = ["s3:Get*", "s3:List*"]
    resources = [local.log_bucket_arn]
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "ManageLogBucketConfig"
      actions   = ["s3:*"]
      resources = [local.log_bucket_arn]
    }
  }

  # Deleting the bucket is never a pipeline job. Object Lock would refuse it
  # while logs are retained anyway, but the explicit Deny makes the intent
  # visible and survives any later change to the Allow above.
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "NeverDeleteLogBucket"
      effect    = "Deny"
      actions   = ["s3:DeleteBucket"]
      resources = [local.log_bucket_arn]
    }
  }
}

resource "aws_iam_role_policy" "log_archive_ci" {
  provider = aws.log_archive
  for_each = data.aws_iam_policy_document.log_archive_ci

  name   = "log-bucket"
  role   = aws_iam_role.log_archive_ci[each.key].id
  policy = each.value.json
}
