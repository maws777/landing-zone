output "ci_role_arns" {
  description = "Roles the app repository's workflows assume (plan on PRs and main, apply in the GitHub environment)."
  value       = { for k, role in aws_iam_role.ci : k => role.arn }
}

output "dns_role_arns" {
  description = "Roles in network the CI roles chain into for their DNS records."
  value       = { for k, role in aws_iam_role.dns : k => role.arn }
}

output "state_bucket_name" {
  description = "The app's Terraform state bucket. Keys must be <stack>/terraform.tfstate (apply may write only those)."
  value       = aws_s3_bucket.state.id
}

output "permissions_boundary_arn" {
  description = "Boundary every role the app creates must carry."
  value       = aws_iam_policy.boundary.arn
}
