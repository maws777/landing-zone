# 02-logging

The organization's audit log (roadmap step 4): one CloudTrail trail covering
every account and region, delivering to a locked bucket in `log-archive`.
Decisions and trade-offs are in
[ADR 0008](../../docs/decisions/0008-organization-trail-and-log-archive.md).

## What it creates

| Resource | Account | Notes |
|---|---|---|
| S3 bucket `landing-zone-org-trail-<log-archive id>` | log-archive | Object Lock (governance, 365 days), versioning, lifecycle expiry after the lock, SSE-S3, ACLs off, public access blocked, `prevent_destroy` |
| Bucket policy | log-archive | Only `cloudtrail.amazonaws.com` writes, only for our trail (`aws:SourceArn`); non-TLS denied |
| Organization trail `landing-zone-org-trail` | management | All regions, global service events, management events only, log file validation |

**Cannot be undone:** Object Lock stays on for the life of the bucket, and each
log file can't be deleted for a year after it's written. The bucket can only
go once every lock has run out.

Cost: no fixed monthly cost. The first copy of management events is free;
S3 storage and PUTs for one person's activity are cents a month.

## Two accounts, one stage

The bucket lives in `log-archive`, the trail in management, and the trail
can't exist before the bucket policy allows it to write. Keeping both in one
stage makes that order a `depends_on` instead of a note in a README.

The second provider (`aws.log_archive`) gets into log-archive one of two ways:

| Who runs it | Identity in log-archive | Set by |
|---|---|---|
| CI, pull request | assumes `ci/landing-zone-ci-logging-plan` | workflow env (`log_archive_role_name`) |
| CI, apply on `main` | assumes `ci/landing-zone-ci-logging-apply` | workflow env (`log_archive_role_name`) |
| Locally | Identity Center profile `log-archive-admin` | `terraform.tfvars` (`log_archive_profile`) |

The CI roles are created by `00-bootstrap` (`log-archive-access.tf`) and can
only touch the bucket's configuration, never the log files. They trust only
the matching CI role in management, so a local admin session can't assume
them. Local runs used `OrganizationAccountAccessRole` until step 6 locked it
with an SCP (ADR 0010); they now sign in to log-archive directly.

## Running it

Normally through CI: open a PR to see the plan, merge to apply (approval in
the `management` environment). Locally, for a read-only plan:

```powershell
aws sso login --profile management-admin
cd stages/02-logging
$env:AWS_PROFILE = "management-admin"
terraform init "-backend-config=backend.hcl"   # bucket name, gitignored
terraform plan
```

`terraform.tfvars` (gitignored) holds `management_account_id` and
`log_archive_profile = "log-archive-admin"`.

## Checking it works

```powershell
# Logging is on, and when the last delivery happened
aws cloudtrail get-trail-status --name landing-zone-org-trail --profile management-admin

# No log file changed or removed since the trail started (digests arrive hourly).
# Run from log-archive-admin: it reads the digests from the bucket with your own
# credentials, and management can't read that bucket (only CloudTrail can write,
# only log-archive can read). An organization trail is validated one account at
# a time, so --account-id is required.
aws cloudtrail validate-logs --trail-arn <trail_arn output> --account-id <account id> --start-time 2026-10-23T13:30:00Z --profile log-archive-admin
```

Then make any call in `sandbox` (read calls are logged too, e.g.
`aws s3api list-buckets --profile sandbox-admin`) and look for it under
`AWSLogs/<organization id>/<sandbox id>/CloudTrail/` in the bucket, from
`log-archive-admin`. Delivery took about a minute on 2026-10-23; AWS says
typically within 5 minutes, up to 15.
