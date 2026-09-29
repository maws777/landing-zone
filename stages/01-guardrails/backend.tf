# Bucket name comes from -backend-config: backend.hcl locally (gitignored),
# the STATE_BUCKET repository variable in CI. See 00-bootstrap/backend.tf.
terraform {
  backend "s3" {
    key          = "stages/01-guardrails/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
