# 01-guardrails

Service Control Policies for the organization (roadmap step 2). The first
stage deployed by GitHub Actions rather than from a laptop.

**Currently empty on purpose.** The first pipeline run has nothing to change,
so it tests the whole chain (OIDC token, role trust, state access, the
approval gate) before the pipeline is trusted with anything real.

## How it's deployed

Through `.github/workflows/terraform.yml`, not by hand:

| Event | Job | Role | Gate |
|---|---|---|---|
| Pull request touching this stage | `plan` | `landing-zone-ci-plan` (read-only) | none |
| Push to `main` touching this stage | `apply` | `landing-zone-ci-apply` | `management` environment: required reviewer, `main` only |

The roles are defined in [`00-bootstrap/ci-identity.tf`](../00-bootstrap/ci-identity.tf),
which CI can't apply (ADR 0004).

This stage can't read `00-bootstrap`'s state (it holds the account root emails,
and the CI roles are denied that key). Anything it needs from the organization,
like OU IDs, comes from data sources.

## Running it locally

For inspection; changes go through a PR.

```powershell
$env:AWS_PROFILE = "management-admin"
Copy-Item ../00-bootstrap/backend.hcl .          # gitignored
Set-Content terraform.tfvars 'management_account_id = "<id>"'   # gitignored
terraform init "-backend-config=backend.hcl"
terraform plan
```

## Provider lock file

`.terraform.lock.hcl` records provider checksums per platform. CI runs on
Linux and this repo is worked on from Windows, so the file must carry both,
or `init` in CI fails the checksum check:

```powershell
terraform providers lock -platform=linux_amd64 -platform=windows_amd64
```
