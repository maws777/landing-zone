# The organization trail, in the management account (ADR 0008).
#
# One trail records API calls in every account of the organization, current
# and future, without anything being set up in those accounts.

resource "aws_cloudtrail" "org" {
  name           = local.trail_name
  s3_bucket_name = aws_s3_bucket.logs.id

  is_organization_trail = true

  # Every region, not just eu-west-3. Calls to global services (IAM, STS,
  # Organizations) are logged in us-east-1, and calls the region SCP denies
  # elsewhere are exactly the ones worth seeing. A single-region trail would
  # miss both.
  is_multi_region_trail         = true
  include_global_service_events = true

  # Every hour CloudTrail writes a digest file: hashes of the log files it
  # delivered, signed with a CloudTrail key. `aws cloudtrail validate-logs`
  # later proves that no file was changed, removed or added in between.
  enable_log_file_validation = true

  # No event_selector block = management events only, read and write. That is
  # the first copy, which CloudTrail doesn't charge for. Data events (every S3
  # object read, every Lambda invoke) cost per event and are left out.

  # CloudTrail checks the bucket policy when the trail is created and refuses
  # to create it if it can't write. The policy has to exist first.
  depends_on = [aws_s3_bucket_policy.logs]
}
