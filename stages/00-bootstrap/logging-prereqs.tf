# The CloudTrail service-linked role, created ahead of the trail (ADR 0008).
#
# A service-linked role is an IAM role whose trust policy and permissions are
# defined by AWS and can't be edited; only the service can use it. CloudTrail
# uses this one to see the organization's accounts and record their events into
# the organization trail.
#
# Normally the first organization trail creates it on the fly, which means the
# caller needs iam:CreateServiceLinkedRole. The trail is created by CI
# (02-logging), and CI deliberately has no IAM write permissions
# (ci-identity.tf). Creating the role here, locally, keeps it that way.
#
# Checked 2026-10-16: the role did not exist yet (no trail ever created).
# Cost: free.

resource "aws_iam_service_linked_role" "cloudtrail" {
  aws_service_name = "cloudtrail.amazonaws.com"
}
