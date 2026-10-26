output "organization_id" {
  description = "The organization's ID."
  value       = aws_organizations_organization.this.id
}

output "organization_root_id" {
  description = "Root ID of the organization; SCPs attach here or to an OU below it."
  value       = aws_organizations_organization.this.roots[0].id
}

output "organizational_unit_ids" {
  description = "OU IDs, for attaching SCPs in a later stage."
  value = {
    security       = aws_organizations_organizational_unit.security.id
    infrastructure = aws_organizations_organizational_unit.infrastructure.id
    workloads      = aws_organizations_organizational_unit.workloads.id
    sandbox        = aws_organizations_organizational_unit.sandbox.id
  }
}

output "account_ids" {
  description = "Member account IDs by name. Needed to build per-account CLI profiles."
  value       = { for name, account in aws_organizations_account.member : name => account.id }
}

output "ci_role_arns" {
  description = "Roles GitHub Actions assumes: plan on pull requests, apply in the `management` environment."
  value       = { for name, role in aws_iam_role.github : name => role.arn }
}

output "log_archive_ci_role_arns" {
  description = "Roles in log-archive that the CI roles chain into to manage the CloudTrail bucket."
  value       = { for name, role in aws_iam_role.log_archive_ci : name => role.arn }
}

output "log_bucket_name" {
  description = "Name 02-logging must give the CloudTrail bucket; the log-archive CI roles are scoped to it."
  value       = local.log_bucket_name
}

output "log_archive_state_bucket_name" {
  description = "Terraform state bucket in log-archive (ADR 0009). Goes in every stage's backend.hcl."
  value       = aws_s3_bucket.la_state.id
}

output "log_archive_state_ci_role_arns" {
  description = "Roles in log-archive that CI's backend assumes to read and lock state."
  value       = { for name, role in aws_iam_role.la_state_ci : name => role.arn }
}
