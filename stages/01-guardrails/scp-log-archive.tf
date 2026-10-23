# SCP: nobody in a member account can weaken the CloudTrail bucket or touch
# the log files in it (roadmap step 4, ADR 0008).
#
# The bucket policy (02-logging) already decides who may write. What it can't
# stop is an admin *inside* log-archive: IAM admins there could rewrite the
# bucket policy, change the lifecycle to delete logs early, or use
# s3:BypassGovernanceRetention to remove locked files. An SCP binds every
# principal in the account, admins and OrganizationAccountAccessRole included,
# so it closes that gap.
#
# Why CloudTrail itself still gets in: SCPs only apply to principals *in*
# member accounts. CloudTrail writes as the service principal
# cloudtrail.amazonaws.com, which no SCP binds. So denying s3:PutObject below
# stops a person or role from planting forged log files, not the trail.
#
# The trail lives in the management account, which SCPs never bind; member
# accounts can't stop or change an organization trail anyway. So this protects
# the bucket, not the trail (ADR 0008). StopLogging/DeleteTrail in management
# are left to the alarms in step 9.

locals {
  log_bucket_arn = "arn:aws:s3:::landing-zone-org-trail-${local.log_archive_account_id}"

  # The one principal that may change the bucket's configuration: the CI apply
  # role in log-archive (00-bootstrap/log-archive-access.tf), reached only
  # through the reviewed, approved apply job. aws:PrincipalArn for an assumed
  # role is the role's ARN, path included, not the session ARN.
  log_bucket_admin_arn = "arn:aws:iam::${local.log_archive_account_id}:role/ci/landing-zone-ci-logging-apply"
}

data "aws_iam_policy_document" "log_archive" {
  # Every way to loosen the bucket. Deleting a policy, lifecycle, encryption or
  # public access block is covered by the matching Put* permission; S3 has no
  # separate IAM action for those deletes.
  statement {
    sid    = "DenyLogBucketConfigChanges"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketObjectLockConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketVersioning",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketAcl",
    ]
    resources = [local.log_bucket_arn]

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [local.log_bucket_admin_arn]
    }
  }

  # The log files themselves. No exception: Terraform never needs objects, and
  # the CI roles were never given object access (their policies name only the
  # bucket ARN). Lifecycle expiry is S3 acting on its own, not a principal, so
  # logs still expire after the lock runs out.
  #
  #   DeleteObject / DeleteObjectVersion : hiding or removing a log file
  #   BypassGovernanceRetention          : the one way past a governance lock
  #   PutObjectRetention                 : changing a file's lock
  #   PutObject                          : planting a forged log file
  statement {
    sid    = "DenyLogFileTampering"
    effect = "Deny"
    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:BypassGovernanceRetention",
      "s3:PutObjectRetention",
      "s3:PutObject",
    ]
    resources = ["${local.log_bucket_arn}/*"]
  }
}

resource "aws_organizations_policy" "log_archive" {
  name        = "log-archive-protection"
  description = "Deny weakening the CloudTrail bucket in log-archive or tampering with its log files. Managed by 01-guardrails."
  type        = "SERVICE_CONTROL_POLICY"

  content = data.aws_iam_policy_document.log_archive.minified_json
}
