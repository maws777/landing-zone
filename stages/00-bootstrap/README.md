# 00-bootstrap

The first Terraform stage. Turns the hand-made organization from
[Day 0](../../docs/day0.md) into managed infrastructure, and creates the
accounts everything later is built in.

Runs in the **management account**, with local state at first, then migrated to
S3. Region `eu-west-3`.

## What it creates

| Resource | Notes |
|---|---|
| The organization | **Imported**, not created — it already exists |
| 4 OUs | Security, Infrastructure, Workloads, Sandbox |
| 6 member accounts | log-archive, security, network, staging, prod, sandbox |
| 6 Identity Center assignments | `admins` group → `AdministratorAccess` on each account |
| S3 state bucket | Versioned, SSE-S3, public access blocked, TLS-only |

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

```powershell
terraform apply "-target=aws_organizations_organization.this" `
                "-target=aws_organizations_organizational_unit.security" `
                "-target=aws_organizations_organizational_unit.infrastructure" `
                "-target=aws_organizations_organizational_unit.workloads" `
                "-target=aws_organizations_organizational_unit.sandbox" `
                "-target=aws_s3_bucket.state"
```

Accounts are held back deliberately — see step 4.

### 3. Migrate state into S3

State is local up to here, because the bucket it belongs in didn't exist yet.
Create `backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket       = "landing-zone-tfstate-<account-id>"
    key          = "stages/00-bootstrap/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
```

Get the bucket name from `terraform output state_bucket_name`. Then:

```powershell
terraform init -migrate-state
```

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

## Decisions worth knowing

**Why state lives in the management account.** The Organizations API can only be
called from the management account, so this stage has to run there. State would
be better placed in `log-archive` — separated from the account it manages — but
log-archive doesn't exist until this stage creates it. That's the bootstrap
chicken-and-egg. Moving it is roadmap step 5, and needs a cross-account bucket
policy plus a role this stage assumes.

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
Roadmap step 6 restricts it, once Identity Center gives every account a real
access path and locking it down can't strand us.

**`ignore_changes = [role_name]` on accounts.** `role_name` can't be read back
through the Organizations API, so Terraform sees it as absent on every refresh
and would want to *replace* the account to fix it — replacing an account means
closing one and creating another. Ignoring it is what keeps a routine plan from
proposing that.
