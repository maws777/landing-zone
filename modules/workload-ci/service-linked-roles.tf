# Service-linked roles the apps need, created here so the app's CI never needs
# iam:CreateServiceLinkedRole (same reasoning as the CloudTrail one in
# 00-bootstrap/logging-prereqs.tf).
#
# API Gateway creates AWSServiceRoleForAPIGateway the first time an API or a
# custom domain is created in an account, using the caller's permissions. Its
# policy is defined by AWS and only API Gateway can use it.

resource "aws_iam_service_linked_role" "apigateway" {
  aws_service_name = "ops.apigateway.amazonaws.com"
}
