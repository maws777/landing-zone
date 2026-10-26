# Terraform state, moved into log-archive (roadmap step 5, ADR 0009).
#
# The first state bucket (state-bucket.tf) had to live in management: this
# stage creates log-archive, so log-archive couldn't hold its state on day one.
# Now that it exists, state moves here. The effect: the account that can change
# the organization no longer also holds the full map of it. Reading state now
# takes a session in a second account.
#
# Who reaches this bucket, and how:
#   you, locally  -> the backend's own `profile = "log-archive-admin"`
#                    (Identity Center session, same account, no cross-account
#                    grant at all). The provider still runs as management-admin.
#   CI            -> landing-zone-ci-{plan,apply}         (management)
#                 -> sts:AssumeRole
#                 -> landing-zone-ci-state-{plan,apply}   (log-archive)
#                    set as `assume_role` in the backend config CI generates.
#
# Because every caller ends up as a principal *inside* log-archive, the bucket
# policy grants nothing to other accounts. Cross-account S3 access needs both
# an identity policy and a bucket policy saying yes; with role chaining only
# the identity policy is needed, so there is one fewer place to get wrong.
#
# The old bucket stays until the migration is verified, as a way back
# (terraform init -migrate-state copies state, it doesn't move it).

locals {
  # Same naming rule as the first bucket: the owning account's ID keeps the
  # global name unique without a random suffix to remember.
  la_state_bucket_name = "landing-zone-tfstate-${local.log_archive_account_id}"
  la_state_bucket_arn  = "arn:aws:s3:::${local.la_state_bucket_name}"
}

resource "aws_s3_bucket" "la_state" {
  provider = aws.log_archive

  bucket = local.la_state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

# Every state write becomes a version, so a broken state can be rolled back.
resource "aws_s3_bucket_versioning" "la_state" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.la_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3, not KMS: same reasoning and trade-off as state-bucket.tf.
resource "aws_s3_bucket_server_side_encryption_configuration" "la_state" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.la_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "la_state" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.la_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning keeps every write forever unless told otherwise, and every plan
# writes and deletes a .tflock object. Without this, old versions and delete
# markers pile up one per run.
#
#   - Old state versions: kept 90 days, and the 10 newest are always kept
#     however old, so a stage nobody touched for months still has history.
#   - Delete markers left with nothing behind them (expired .tflock files):
#     removed.
#   - Uploads that never finished: cleaned up after a week.
resource "aws_s3_bucket_lifecycle_configuration" "la_state" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.la_state.id

  rule {
    id     = "state-history"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10
    }

    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Lifecycle rules on noncurrent versions only make sense once versioning is
  # on; AWS recommends the explicit ordering.
  depends_on = [aws_s3_bucket_versioning.la_state]
}

data "aws_iam_policy_document" "la_state_tls_only" {
  statement {
    sid    = "DenyNonTLSRequests"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.la_state.arn,
      "${aws_s3_bucket.la_state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "la_state" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.la_state.id
  policy = data.aws_iam_policy_document.la_state_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.la_state]
}

# ---------------------------------------------------------------------------
# CI's way into the state: one role per CI role, same pattern as the log
# bucket roles (log-archive-access.tf). Separate roles rather than more
# permissions on those: one role per job keeps each policy readable on its own.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "la_state_ci" {
  provider = aws.log_archive
  for_each = aws_iam_role.github

  name        = "landing-zone-ci-state-${each.key}"
  path        = "/ci/"
  description = "Assumed by the management CI ${each.key} role for Terraform state. Managed by 00-bootstrap."

  # Same trust as the log bucket roles: only the matching CI role, by exact ARN.
  assume_role_policy   = data.aws_iam_policy_document.log_archive_trust[each.key].json
  max_session_duration = 3600
}

# The same rules as ci_state in ci-identity.tf, pointed at the new bucket:
# read and lock every stage's state, write it only from apply, and never touch
# 00-bootstrap's (it holds the root emails).
data "aws_iam_policy_document" "la_state_ci" {
  for_each = toset(["plan", "apply"])

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.la_state_bucket_arn]
  }

  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${local.la_state_bucket_arn}/stages/*"]
  }

  statement {
    sid       = "LockState"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.la_state_bucket_arn}/stages/*.tflock"]
  }

  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "WriteState"
      actions   = ["s3:PutObject"]
      resources = ["${local.la_state_bucket_arn}/stages/*/terraform.tfstate"]
    }
  }

  statement {
    sid       = "NeverBootstrapState"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["${local.la_state_bucket_arn}/stages/00-bootstrap/*"]
  }
}

resource "aws_iam_role_policy" "la_state_ci" {
  provider = aws.log_archive
  for_each = data.aws_iam_policy_document.la_state_ci

  name   = "terraform-state"
  role   = aws_iam_role.la_state_ci[each.key].id
  policy = each.value.json
}
