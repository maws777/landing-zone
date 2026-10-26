# Bucket name comes from -backend-config: backend.hcl locally (gitignored),
# a file the workflow writes in CI (bucket + assume_role). State lives in
# log-archive, ADR 0009.
terraform {
  backend "s3" {
    key          = "stages/02-logging/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
