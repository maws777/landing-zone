output "scp_ids" {
  description = "SCP IDs by short name."
  value       = local.policies
}

output "scp_attachments" {
  description = "Which policy is attached to which target (policy/target => target ID)."
  value       = { for key, attachment in aws_organizations_policy_attachment.this : key => attachment.target_id }
}
