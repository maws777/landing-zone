# Remote state in the S3 bucket this stage created (state-bucket.tf).
#
# The bucket name is deliberately missing: it contains the management account
# ID and this file is public. It comes from the gitignored backend.hcl instead,
# via `terraform init "-backend-config=backend.hcl"`. See the README, step 3.
terraform {
  backend "s3" {
    key          = "stages/00-bootstrap/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
