# 00-bootstrap

The first Terraform stage. Turns the hand-made organization from
[Day 0](../../docs/day0.md) into managed infrastructure, and creates the
accounts everything later is built in.

Runs in the **management account**, with local state at first, then migrated to
S3 in management, and since step 5 to S3 in log-archive (step 7 below). Region
`eu-west-3`.

## What it creates

| Resource | Notes |
|---|---|
| The organization | **Imported**, not created — it already exists |
| 4 OUs | Security, Infrastructure, Workloads, Sandbox |
| 6 member accounts | log-archive, security, network, staging, prod, sandbox |
| 6 Identity Center assignments | `admins` group → `AdministratorAccess` on each account |
| S3 state bucket (log-archive) | `state-log-archive.tf`: versioned, SSE-S3, public access blocked, TLS-only, history expiry, plus CI state roles; ADR 0009 |
| GitHub OIDC provider + CI roles | `ci-identity.tf`, ADR 0004 |
| Read-only access | `read-only-access.tf`: `ViewOnlyAccess` permission set, `readers` group (you + `test-reader`) on all 7 accounts, ADR 0010 |
| Centralized root access | `root-access.tf`: IAM trusted access + `RootCredentialsManagement` + `RootSessions`, ADR 0007 |

Account layout:

| OU | Accounts | Why |
|---|---|---|
| Security | log-archive, security | Audit and log retention, kept away from workloads so compromising an app doesn't also mean rewriting the evidence |
| Infrastructure | network | Shared plumbing, no application code |
| Workloads | staging, prod | Separate accounts, not just separate VPCs — the account is the strongest boundary AWS has |
| Sandbox | sandbox | Loose SCPs later, so the detective controls have something real to catch in a demo |

## Cost

Effectively nothing. Organizations, OUs, accounts, Identity Center and
assignments are all free. The state bucket is a few cents a month at this size.

Encryption is **SSE-S3, not KMS**, on purpose: a customer-managed KMS key is
$1/month, which is a real slice of a €10–15 budget. The tradeoff is no separate
key policy, so access rests on the bucket policy and IAM. Fine for one operator
with public access blocked; a shared environment would justify the dollar.

## Prerequisites

- Terraform >= 1.10 (1.10 added native S3 state locking, which is why there's no
  DynamoDB table here)
- A valid SSO session: `aws sso login --profile management-admin`
- `terraform.tfvars` created from `terraform.tfvars.example`

## Running it

```powershell
$env:AWS_PROFILE = "management-admin"
```

Terraform doesn't take `--profile`, so this is how it picks the SSO credentials.
Forget it and Terraform walks the default credential chain and uses whatever it
finds first.

That's why the provider also has `allowed_account_ids`. It doesn't choose
credentials, it checks them: before anything else, the provider asks STS which
account the credentials belong to and stops if it isn't `management_account_id`.
If you see `AWS account ID not allowed`, you're authenticated to the wrong
account — check `AWS_PROFILE`, don't debug the config.

### 1. Import the organization

```powershell
terraform init
terraform plan "-target=aws_organizations_organization.this"
```

The quotes matter in PowerShell: unquoted, it splits `-target=a.b` at the dot
and Terraform receives a broken argument ("Invalid target").

**Read this plan carefully — it's the one genuinely dangerous step in the stage.**

`aws_service_access_principals` is a whole-list attribute: Terraform sets it to
exactly what `organization.tf` declares, so anything enabled in AWS but missing
from that list gets *disabled* on apply.

Currently enabled in the organization: `sso.amazonaws.com` (only).
Declared in `organization.tf`: `sso.amazonaws.com` + `cloudtrail.amazonaws.com`.

A correct plan **adds** `cloudtrail.amazonaws.com` and **removes nothing**. If it
proposes removing `sso.amazonaws.com`, stop — applying that disables Identity
Center trusted access and breaks the only sign-in path into the organization.

### 2. Organization, OUs and state bucket

> **Steps 2 and 3 are the day-one history.** The management state bucket they
> create was removed in roadmap step 5 (`state-bucket.tf` is gone). A rebuild
> from scratch keeps local state through step 4, creates the log-archive
> bucket (step 7, `state-log-archive.tf` with `-target`), and migrates once,
> straight into it.

```powershell
terraform plan "-out=ous-bucket.tfplan" `
  "-target=aws_organizations_organization.this" `
  "-target=aws_organizations_organizational_unit.security" `
  "-target=aws_organizations_organizational_unit.infrastructure" `
  "-target=aws_organizations_organizational_unit.workloads" `
  "-target=aws_organizations_organizational_unit.sandbox" `
  "-target=aws_s3_bucket.state" `
  "-target=aws_s3_bucket_versioning.state" `
  "-target=aws_s3_bucket_server_side_encryption_configuration.state" `
  "-target=aws_s3_bucket_public_access_block.state" `
  "-target=aws_s3_bucket_policy.state"
terraform apply ous-bucket.tfplan
Remove-Item ous-bucket.tfplan
```

Every bucket resource is listed explicitly. `-target` pulls in what a target
*depends on*, not what depends *on it*: versioning, encryption, the public
access block and the policy all reference the bucket, so targeting only
`aws_s3_bucket.state` would create a bare bucket and migrate state into it
unprotected.

Accounts are held back deliberately — see step 4.

### 3. Migrate state into S3

State is local up to here, because the bucket it belongs in didn't exist yet.
Create `backend.tf`:

```hcl
terraform {
  backend "s3" {
    # bucket comes from backend.hcl, see below
    key          = "stages/00-bootstrap/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
```

The bucket name is left out on purpose. It contains the management account
ID, and `backend.tf` is committed to a public repo. Terraform allows a
*partial* backend configuration: anything missing from the `backend` block is
supplied at `init` time. So the name goes in `backend.hcl`, which is gitignored:

```powershell
Copy-Item backend.hcl.example backend.hcl
terraform output state_bucket_name   # put this value in backend.hcl
terraform init "-backend-config=backend.hcl" -migrate-state
```

Terraform stores the merged backend settings in `.terraform/`, so later runs
only need a plain `terraform init` (or `-backend-config` again on a fresh
clone).

Terraform notices the backend changed and offers to copy existing state up.
Answer `yes`. It uploads `terraform.tfstate` to the bucket and stops using the
local file — verify with `terraform plan`, which should show no changes.

`use_lockfile = true` is native S3 locking: Terraform writes a `.tflock` object
next to the state and relies on S3's conditional writes so two applies can't
interleave. Before 1.10 this needed a DynamoDB table, which is a second resource
to create, pay for, and forget about.

`backend.tf` is not committed to the repo before this step, because
`terraform init` fails against a bucket that doesn't exist yet.

### 4. Member accounts — confirm first

**Stop here and check the list and the email addresses**, because this is the
step that's expensive to undo. Closing an AWS account puts it in a 90-day
suspended state, and the number closable per rolling 30 days is a percentage of
the accounts in the organization — at 7 accounts, roughly one. A typo in a root
email is a problem measured in months.

Quota check (2026-09-24): "Maximum number of accounts" is **10**, with **1** in
use, so 6 new accounts lands at 7 of 10. Adjustable via a support request.

The quota is only readable from `us-east-1` — Organizations is a global service
and doesn't expose quotas in `eu-west-3`:

```powershell
aws service-quotas get-service-quota --service-code organizations `
  --quota-code L-E619E033 --region us-east-1
```

Then:

```powershell
terraform plan    # should show 6 accounts + 6 assignments
terraform apply
```

Account creation takes a minute or two each and is asynchronous underneath.

### 5. Per-account CLI profiles

Each assignment creates an IAM role named
`AWSReservedSSO_AdministratorAccess_<suffix>` inside the target account. Add a
profile per account, following the `<account>-admin` pattern:

```powershell
aws configure sso --profile prod-admin
```

Reuse the existing SSO session when prompted, and the account list will include
the new accounts. Or write them into `~/.aws/config` directly:

```ini
[profile prod-admin]
sso_session = <sso-session-name>
sso_account_id = <prod account id>
sso_role_name = AdministratorAccess
region = eu-west-3
```

`sso_role_name` is the *permission set* name, not the generated role name — the
suffix doesn't appear here.

Account IDs come from `terraform output account_ids`. Verify with:

```powershell
aws sts get-caller-identity --profile prod-admin
```

### 6. Removing member root credentials

After `root-access.tf` is applied, the management account can delete each
member account's root password, keys, signing certificates and MFA. That is a
one-off action per account, not a resource, so it's a script, run from the
repo root:

```powershell
aws sso login --profile management-admin
./scripts/root-credentials.ps1 -Action Audit                          # read-only, all member accounts
./scripts/root-credentials.ps1 -Action Delete -AccountId <one id>     # try one first
./scripts/root-credentials.ps1 -Action Delete                         # then the rest
./scripts/root-credentials.ps1 -Action Audit                          # everything should be false/0
```

Each account gets its own `sts:AssumeRoot` session (15 minutes), scoped by an
AWS-managed task policy (`IAMAuditRootUserCredentials` or
`IAMDeleteRootUserCredentials`) that denies everything except those few IAM
calls on the root user. `Delete` asks before changing anything.

Accounts created after the feature was enabled have no root credentials to
begin with. To get a member root back for a task `AssumeRoot` can't do: IAM
console → Root access management → the account → **Allow password recovery**,
then reset the password from the account's root email. Delete the credentials
again afterwards.

### 7. Move state to log-archive (roadmap step 5, ADR 0009)

`state-log-archive.tf` creates a second state bucket inside `log-archive` and
the roles CI uses to reach it. Locally, the backend reads it with the
`log-archive-admin` profile (a `profile` line in `backend.hcl`), while the
provider keeps running as `management-admin`. One `aws sso login` covers both.

The order matters, so CI and local runs never disagree about where state is:

```powershell
# 1. Create the bucket and roles. CI keeps using the old bucket meanwhile.
$env:AWS_PROFILE = "management-admin"
cd stages/00-bootstrap
terraform plan "-out=step5.tfplan"
terraform apply step5.tfplan
Remove-Item step5.tfplan
terraform output log_archive_state_bucket_name

# 2. Point backend.hcl at the new bucket (see backend.hcl.example: bucket +
#    profile), then copy state over. Answer "yes" to the copy prompt.
#    Nothing may merge to main between here and step 3.
terraform init "-backend-config=backend.hcl" -migrate-state
terraform plan    # expect: No changes
# Same in 01-guardrails and 02-logging, each with the new backend.hcl.

# 3. PR that switches the workflow to the new bucket; its plans must show
#    "No changes" for both stages.
```

`-migrate-state` copies; the old bucket kept the last state of every stage,
which was the way back until CI was verified on the new bucket (PR #12, run
"No changes" for both stages). A clean-up change then removed CI's access to
the old bucket and the bucket itself, after emptying it: S3 refuses to delete
a bucket that still holds object versions or delete markers.

Note the migrated copies got a new lineage and serial 1. Harmless, and it
means an old state file can't be pushed over the new one by accident.

### 8. Read-only access (roadmap step 6, ADR 0010)

`read-only-access.tf` adds a `ViewOnlyAccess` permission set and a `readers`
group on every account, with you and a `test-reader` user in it. Locally this
stage now needs two profiles: `management-admin` (AWS_PROFILE) and
`log-archive-admin` (the log-archive provider and the state backend).

Read-only CLI profiles, one per account, same pattern as step 5:

```ini
[profile prod-readonly]
sso_session = <sso-session-name>
sso_account_id = <prod account id>
sso_role_name = ViewOnlyAccess
region = eu-west-3
```

`test-reader` is created without a password, and Identity Center doesn't email
users created through the API. For its first sign-in: IAM Identity Center
console → Users → `test-reader` → Reset password → send an email. Then sign
in at the portal in a private window and check it sees resources but can't
change them or read S3 objects.

## Decisions worth knowing

**Where state lives.** The Organizations API can only be called from the
management account, so this stage has to run there, and on day one its state
had to be there too: log-archive didn't exist until this stage created it
(the bootstrap chicken-and-egg). Step 5 moved state into `log-archive`, so the
account that can change the organization no longer holds the map of it
(ADR 0009).

**Why the organization is imported.** An organization must exist before the
Organizations API works at all, so it can't be Terraform's creation. An `import`
block adopts it declaratively — the plan shows the adoption before anything
happens, and it stays in the repo as a record of where the organization came
from, which `terraform import` on the CLI wouldn't.

**`OrganizationAccountAccessRole`.** Creating an account through Organizations
also creates this role inside it: `AdministratorAccess`, trusting the management
account. It's the bootstrap access path — without it a new account has no way in
but its root user. It's also a wide door: anyone who can assume roles from
management gets full admin everywhere, and its use is only visible in CloudTrail.
Step 6 locks it with an SCP that denies it every action (ADR 0010); detaching
that SCP from management is the break-glass path. Nothing here uses the role
any more: the log-archive provider signs in with the `log-archive-admin`
profile.

**`ignore_changes = [role_name]` on accounts.** `role_name` can't be read back
through the Organizations API, so Terraform sees it as absent on every refresh
and would want to *replace* the account to fix it — replacing an account means
closing one and creating another. Ignoring it is what keeps a routine plan from
proposing that.
