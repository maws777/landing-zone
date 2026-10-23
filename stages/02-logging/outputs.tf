output "log_bucket_name" {
  description = "CloudTrail bucket in log-archive."
  value       = aws_s3_bucket.logs.id
}

output "trail_arn" {
  description = "The organization trail. Needed for `aws cloudtrail validate-logs`."
  value       = aws_cloudtrail.org.arn
}
