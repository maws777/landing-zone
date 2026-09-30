# 01-guardrails

Service Control Policies for the organization (roadmap step 2): the
preventive half of the guardrails. The first stage deployed by GitHub Actions
rather than from a laptop.

## What it creates

| SCP | Denies | Attached to |
|---|---|---|
| `baseline-protections` | Leaving the organization; any use of a member account's root password or keys (short-lived `AssumeRoot` sessions still work) | Sandbox OU |
| `region-restriction` | Any action outside `eu-west-3`, except global services (list copied from AWS's Region deny control) | Sandbox OU |

Why each statement exists is commented in `scp-baseline.tf` and
`scp-region.tf`. The reasoning behind the overall approach is in
[ADR 0006](../../docs/decisions/0006-scp-strategy.md).

Cost: none. SCPs are free.

## How SCPs behave (the short version)

- **A ceiling, not a grant.** An action succeeds only if IAM allows it *and*
  every SCP from the root down to the account allows it. These policies are
  Deny statements on top of AWS's `FullAWSAccess`, which must stay attached at
  the root. Detach it and member accounts can do nothing.
- **They bind everyone in a member account**, including admins, the root user
  and `OrganizationAccountAccessRole`.
- **They never apply to the management account.** So CI and
  `management-admin` are unaffected, and a bad SCP can always be fixed from
  there.
- **Limits:** 5 SCPs per target (including `FullAWSAccess`), 5,120 characters
  per policy.

## Rollout

Attachments live in `attachments.tf`, in `local.scp_targets`, one PR per step:

1. **Sandbox OU only** (current). Test from `sandbox-admin`, see below.
2. **Organization root.** Replace the Sandbox entry with the root, so every
   current and future account inherits the policies.

### Testing an attachment

```powershell
aws sso login --profile management-admin   # the session covers sandbox-admin too

# Outside the home region: should fail with
# "... with an explicit deny in a service control policy"
aws ec2 describe-vpcs --region us-east-1 --profile sandbox-admin

# Home region: should work
aws ec2 describe-vpcs --region eu-west-3 --profile sandbox-admin

# Global service: should work (IAM is exempt from the region rule)
aws iam list-roles --max-items 1 --profile sandbox-admin
```

Leaving the organization is tested by reading the policy, not by trying it.

## Deliberately not here yet

- **CloudTrail and log-bucket protection.** Moves to roadmap step 4, written
  together with the org trail and the log-archive bucket it protects.
- **A relaxed Sandbox variant.** Nothing above blocks the risky changes the
  detective demos need (a public bucket, SSH open to the world), so there is
  nothing to relax. It becomes real when Workloads gets stricter preventive
  SCPs that Sandbox deliberately won't get.

## How it's deployed

Through `.github/workflows/terraform.yml`, not by hand:

| Event | Job | Role | Gate |
|---|---|---|---|
| Pull request touching this stage | `plan` | `landing-zone-ci-plan` (read-only) | none |
| Push to `main` touching this stage | `apply` | `landing-zone-ci-apply` | `management` environment: required reviewer, `main` only |

The roles are defined in [`00-bootstrap/ci-identity.tf`](../00-bootstrap/ci-identity.tf),
which CI can't apply (ADR 0004).

This stage can't read `00-bootstrap`'s state (it holds the account root emails,
and the CI roles are denied that key). The root and OU IDs come from data
sources in `organization.tf`.

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
