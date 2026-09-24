# S3 bucket holding Terraform state for this stage and later ones.
#
# Why it lives in the management account: the Organizations API can only be
# called from the management account, so this stage has to run there regardless.
# The tidier arrangement would put state in log-archive, separating state from
# the account it manages - but log-archive does not exist until this stage
# creates it. That is the bootstrap chicken-and-egg. Moving it is roadmap
# step 5; see the stage README.

data "aws_caller_identity" "current" {}

locals {
  # S3 bucket names are globally unique across all AWS customers, so the account
  # ID is included to avoid collisions without inventing a random suffix that
  # would then have to be remembered.
  state_bucket_name = "landing-zone-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  lifecycle {
    # Losing this bucket means losing the record of what Terraform manages.
    # The resources would still exist in AWS, unowned and awkward to reimport.
    prevent_destroy = true
  }
}

# Every state write becomes a new version, so a corrupted or truncated state
# file can be rolled back to the previous one. This is the main reason a plain
# bucket is not good enough for state.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256), deliberately not KMS. State files contain resource metadata
# and sometimes secrets, so encryption at rest is worth having - but a
# customer-managed KMS key costs $1/month, which is a noticeable slice of a
# EUR 10-15 budget. SSE-S3 is free and encrypts with keys AWS manages.
#
# The tradeoff being accepted: with SSE-S3 there is no separate key policy, so
# access is controlled by the bucket policy and IAM alone. With one operator and
# a bucket that blocks all public access, that is enough. A shared environment
# would justify the dollar.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Belt and braces: nothing in this bucket should ever be public, and these four
# settings make a public ACL or bucket policy impossible rather than merely
# absent. This is the control that would have prevented most of the S3 breaches
# that made the news.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Refuse any request that is not over TLS.
#
# S3 endpoints accept both HTTP and HTTPS by default, and aws:SecureTransport is
# false on the plain-HTTP ones. Without this, a misconfigured client could send
# state - including anything sensitive inside it - across the network in clear
# text, and nothing would complain.
data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid    = "DenyNonTLSRequests"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  # The public access block must exist first: block_public_policy inspects
  # policies as they are applied, and applying a policy to a bucket that is not
  # yet protected is the window this dependency closes.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
