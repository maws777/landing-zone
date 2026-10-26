# Remote state in the S3 bucket this stage created (state-log-archive.tf).
#
# The bucket name is deliberately missing: it contains the log-archive account
# ID and this file is public. It comes from the gitignored backend.hcl instead,
# via `terraform init "-backend-config=backend.hcl"`, along with the profile the
# backend uses (ADR 0009). See the README, steps 3 and 7.
terraform {
  backend "s3" {
    key          = "stages/00-bootstrap/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
