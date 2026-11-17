output "bus_arn" {
  description = "The central detection bus. The StackSet's forwarding rules (00-bootstrap) target it."
  value       = aws_cloudwatch_event_bus.detection.arn
}

output "remediate_role_arn" {
  description = "The Lambda's role. Each account's lz-remediation role (StackSet) trusts exactly this ARN."
  value       = aws_iam_role.remediate.arn
}
