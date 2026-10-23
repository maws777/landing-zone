# The CloudTrail bucket in log-archive (ADR 0008).
#
# Evidence is only worth something if the people it records can't change it.
# So it lives outside the accounts it describes, and every log file is locked
# against deletion for a year from the moment it's written.

resource "aws_s3_bucket" "logs" {
  provider = aws.log_archive

  bucket = local.log_bucket_name

  # Object Lock can only be switched on when the bucket is created, and never
  # off again. It also turns on versioning permanently: a lock protects one
  # object *version*, so S3 must keep versions to have something to protect.
  object_lock_enabled = true

  # Belt and braces. With locked objects inside, S3 refuses to delete the
  # bucket anyway; this stops Terraform from even planning it.
  lifecycle {
    prevent_destroy = true
  }
}

# Every new object version gets a 365-day lock automatically, so CloudTrail
# needs no extra headers when it writes.
#
# GOVERNANCE, not COMPLIANCE: a principal holding s3:BypassGovernanceRetention
# can still delete early. COMPLIANCE would stop even root, and a typo in the
# retention would be a year of storage nobody can remove. The SCP that comes
# after this stage denies the bypass in member accounts, which closes most of
# the gap (ADR 0008).
resource "aws_s3_bucket_object_lock_configuration" "logs" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.logs.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.log_retention_days
    }
  }
}

# Object Lock already forces versioning on; declaring it keeps Terraform's view
# in line with the bucket's, so the plan never proposes "suspending" it.
resource "aws_s3_bucket_versioning" "logs" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Storage stops growing once the lock runs out.
#
# How deletion works in a versioned bucket, which is why there are two steps:
#   day 366 : "expiration" adds a delete marker; the log file becomes a
#             noncurrent version (still stored, still billed)
#   +1 day  : "noncurrent_version_expiration" removes that version for good
#             (its lock ran out at day 365, so S3 allows it)
#   later   : the second rule cleans up the delete markers left behind
# Lifecycle never removes a version that is still locked, so this can't cut
# the retention short even if the numbers were wrong.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-after-retention"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days + 1
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  # Versioning has to be on before lifecycle rules about versions apply.
  depends_on = [aws_s3_bucket_versioning.logs]
}

# SSE-S3 (AES256), not KMS: a customer-managed key would be about $1/month
# fixed. Same trade-off as the state bucket (ADR 0008).
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs off: the bucket owner (log-archive) owns every object, whoever wrote it.
# Without this, files CloudTrail writes could end up owned by another account.
resource "aws_s3_bucket_ownership_controls" "logs" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Who may write: CloudTrail, for our one trail, and nobody else.
#
# The three CloudTrail statements follow AWS's documented policy for an
# organization trail. Every one carries aws:SourceArn = our trail. Without it,
# "cloudtrail.amazonaws.com may write here" would mean *any* trail in *any*
# AWS account could deliver into this bucket: the service would act on a
# stranger's behalf with our permission (the confused deputy problem).
data "aws_iam_policy_document" "logs" {
  # CloudTrail reads the bucket ACL to check it may write before it creates
  # or updates the trail.
  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  # An organization trail writes in two places: the management account's own
  # events under AWSLogs/<management id>/, and every member's under
  # AWSLogs/<organization id>/<account id>/.
  statement {
    sid     = "CloudTrailWrite"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.logs.arn}/AWSLogs/${var.management_account_id}/*",
      "${aws_s3_bucket.logs.arn}/AWSLogs/${local.organization_id}/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }

    # CloudTrail sends this header on every write. Kept from AWS's policy even
    # though ACLs are disabled: with BucketOwnerEnforced it is the one ACL
    # value S3 still accepts.
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "DenyNonTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  provider = aws.log_archive

  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  # Terraform would otherwise send both calls at once, and S3 can answer
  # parallel config changes on one new bucket with "OperationAborted: A
  # conflicting conditional operation is in progress". Ordering avoids a flaky
  # first apply.
  depends_on = [aws_s3_bucket_public_access_block.logs]
}
