# Centralized root access for member accounts (roadmap step 3, ADR 0007).
#
# Every AWS account has a root user, and for the member accounts that root user
# is identified by an email address. Accounts created by Organizations start
# without a root password, but anyone who can read the root email inbox can set
# one through "Forgot password" and become root. All six member root emails are
# aliases of one inbox, so that inbox is a master key to six accounts.
#
# This turns on two IAM features for the organization:
#
#   RootCredentialsManagement  The management account can delete a member
#                              account's root password, access keys, signing
#                              certificates and MFA. Once deleted, the member
#                              account can't sign in as root or recover the
#                              password. Accounts created afterwards start with
#                              no root credentials at all.
#
#   RootSessions               The management account can call sts:AssumeRoot to
#                              get a short root session (15 minutes max) in a
#                              member account, scoped by an AWS-managed task
#                              policy to one job: audit or delete root
#                              credentials, allow password recovery, or unlock an
#                              S3 bucket / SQS queue whose policy denies everyone.
#                              The deletion itself runs through such a session,
#                              so both features are needed.
#
# Turning the features on deletes nothing. Existing root credentials stay until
# they are removed per account, which is an action, not a resource: see the
# README, "Removing member root credentials".
#
# The baseline-protections SCP (01-guardrails) already denies long-term root
# credentials and lets AssumeRoot sessions through (Null aws:AssumedRoot), so
# the two controls stack: the SCP limits what a root login can do, this removes
# the login.
#
# The management account's own root user is not covered; the feature only
# applies to member accounts.
#
# Cost: free.

resource "aws_iam_organizations_features" "this" {
  enabled_features = [
    "RootCredentialsManagement",
    "RootSessions",
  ]

  # IAM refuses to enable these until Organizations has granted IAM trusted
  # access (iam.amazonaws.com in organization.tf). Nothing here references the
  # organization, so without depends_on Terraform could run both at once and
  # this call would fail with ServiceAccessNotEnabledException.
  depends_on = [aws_organizations_organization.this]
}
