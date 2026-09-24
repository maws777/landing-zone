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

output "state_bucket_name" {
  description = "Terraform state bucket. Referenced by the s3 backend block."
  value       = aws_s3_bucket.state.id
}
