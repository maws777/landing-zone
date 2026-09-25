# Session log

Running notes on what happened when, so picking the work back up doesn't mean
re-deriving where things stood. Newest session first.

---

## 2026-09-25 — root key revoked, credentials pinned, org import plan clean

### Done

**Stray root key dealt with, in the right order.** Deleted the access key in the
old account's root security credentials first. Verified from this machine:
`aws sts get-caller-identity --profile default` now returns
`InvalidClientTokenId`, meaning AWS no longer recognises the key. Then deleted
`~/.aws/credentials` (it held only that `[default]` profile). The machine now
has no long-lived AWS credentials at all, only the SSO config.

**Bootstrap stage pinned to the management account.** Resolved the open design
question from last session with `allowed_account_ids = [var.management_account_id]`
in the provider block, instead of `profile = "management-admin"`.

- The two jobs are separate. `AWS_PROFILE` *chooses* credentials;
  `allowed_account_ids` *checks* them. The provider calls
  `sts:GetCallerIdentity` before anything else and stops if the account doesn't
  match.
- Not `profile`: that hardcodes a laptop-only name that won't exist in GitHub
  Actions (OIDC supplies credentials through env vars), and it still wouldn't
  verify which account the profile points at.
- Not a hand-written `aws_caller_identity` precondition: more code, and it runs
  during the plan, after other data sources may already have read from the
  wrong account.
- The account ID is in the gitignored `terraform.tfvars`, with a 12-digit
  validation on the variable.

Tested both ways. With `-var management_account_id=111111111111` the plan
stops with `AWS account ID not allowed`. With the real ID the plan runs.

**PowerShell gotcha:** unquoted `-target=aws_x.name` is split at the dot and
Terraform reports `Invalid target`. Quote the whole argument. README commands
fixed.

### Org import plan: correct

`terraform plan "-target=aws_organizations_organization.this"`:
`1 to import, 0 to add, 1 to change, 0 to destroy`. The only change adds
`cloudtrail.amazonaws.com` to `aws_service_access_principals`; `sso.amazonaws.com`
stays. `feature_set` and `SERVICE_CONTROL_POLICY` already match. Not applied yet.

### Next

Resume at step 2 of the bootstrap sequence below (apply org + OUs + state
bucket), after confirming the import plan.

---

## 2026-09-24 / 25 — Day 0 docs written, bootstrap stage written but not applied

### Done

**App scope changed: RAG app → MCP server.** CLAUDE.md pillar 2 and roadmap
step 8 rewritten. The app is now a remote MCP server giving Claude retrieval over
my own corpus: same ECS Fargate + ALB + WAF + ACM + pgvector infrastructure, but
Bedrock is used for **embeddings only** — Claude is the client and does the
generating, so the app makes no inference calls. Cheaper, and the OAuth 2.1
endpoint gives the threat model real content (token scope, tenant isolation,
prompt injection via retrieved documents, WAF rate limiting).

Still undecided, each to get an ADR: the OAuth approach (Cognito is the likely
cheap answer) and the corpus (something with a reason to exist — project docs,
ADRs, coursework notes).

**Day 0 documentation** — committed as `60463bf`:

- `docs/day0.md` — seven-step runbook of the manual setup with reasoning for
  each step, the permission-set → `AWSReservedSSO_*` role mechanism, the CLI SSO
  PKCE flow, and a "things that went wrong" section covering the three AWS
  sign-in pages
- `docs/decisions/0001-aws-as-cloud-provider.md`
- `docs/decisions/0002-no-control-tower.md`
- `docs/decisions/0003-identity-center-single-region.md`

Account IDs, email addresses and the real portal subdomain are kept out of these
files — the repo will be public.

**Roadmap gained a step 5:** move Terraform state out of the management account
into log-archive once that account exists. Later steps renumbered.

**Bootstrap stage written and validated, nothing applied.** All of
`stages/00-bootstrap/` exists: `versions.tf`, `imports.tf`, `organization.tf`,
`accounts.tf`, `identity-center.tf`, `state-bucket.tf`, `variables.tf`,
`outputs.tf`, `README.md`, `terraform.tfvars` (gitignored, verified) and
`.example`. `terraform init` and `validate` both pass on provider 6.66.0.

### Facts established against the live account

Read-only checks, all via `--profile management-admin`:

| Thing | Value |
|---|---|
| Organization ID | `o-zwsk12p8wd`, feature set ALL |
| Root ID | `r-tmym` |
| Trusted access enabled | `sso.amazonaws.com` **only** |
| SCP policy type | already ENABLED |
| Identity Center instance | one, ACTIVE, `eu-west-3` |
| Permission set | `AdministratorAccess`, 8-hour session |
| Group | `admins` |
| Accounts in org | 1 (`mte-management`) |
| Account quota | **10 max**, 1 used → 6 new lands at 7 of 10 |

The account quota is only readable from `us-east-1` — Organizations is a global
service and exposes no quotas in `eu-west-3`. Same reason the region-restriction
SCP will need a global-service carve-out.

Confirmed decisions: the six accounts as listed, the `+aws-<account>` Gmail alias
pattern (real values in the gitignored `terraform.tfvars`), state bucket stays in
management with the tradeoff noted in the stage README.

### Blocked — pick up here

**The organization import failed, and the cause is not in the Terraform.**

`terraform plan -target=aws_organizations_organization.this` returned
`Error: couldn't find resource`. The config is fine. The cause: Terraform
doesn't accept `--profile`, `AWS_PROFILE` was unset, so it walked the default
credential chain and authenticated against a **different account entirely** —
my main personal account, as **root**, from a `[default]` profile in
`~/.aws/credentials`. An account with no organization in it, so the error was
correct.

**The root access key in `~/.aws/credentials` is still live.** I assumed I'd
deleted that pair in AWS already; `aws sts get-caller-identity` succeeded with
exit 0 and returned the root ARN, so whatever I deleted, it wasn't this one. An
unrestricted, non-expiring root credential in plaintext on disk — exactly what
this project's Day 0 notes say shouldn't exist.

Order of operations tomorrow, and the order matters:

1. **Revoke the key in AWS first.** Sign in as root on that account → IAM → My
   security credentials → Access keys → Delete. `aws iam list-access-keys`
   identifies it without exposing the secret. Deleting the local file does *not*
   revoke the key; only this does, and it stays valid anywhere else it exists.
2. **Then delete `~/.aws/credentials`.** The `[default]` profile is the only
   thing in it. Housekeeping once the key is dead.
3. **Open question worth answering:** has that key ever been anywhere but this
   machine — a git repo, CI config, Dockerfile, old laptop, screenshot? If yes,
   step 1 is urgent rather than hygienic.

The `management-admin` SSO profile is separate and unaffected by all of this.
Deleting that file is an improvement for Terraform too: it will then fail loudly
with "no credentials" rather than silently using the wrong account.

**Unresolved design question this exposed:** how the bootstrap stage should pin
its credentials. Options are a `profile` argument in the provider block, or an
`aws_caller_identity` check that fails the plan when the account ID isn't the
expected one, or both. I started on the provider-block version and didn't finish
it. Worth deciding deliberately rather than relying on remembering to set an
environment variable, because the failure mode is silent and points at the wrong
account.

### Then, to finish the bootstrap

Following `stages/00-bootstrap/README.md`:

1. Plan the org import **alone** and read it carefully. Correct plan **adds**
   `cloudtrail.amazonaws.com` and **removes nothing**. If it proposes removing
   `sso.amazonaws.com`, stop — that disables Identity Center trusted access and
   breaks the only sign-in path into the organization.
2. Apply org + OUs + state bucket.
3. Migrate state to S3: add `backend.tf`, `terraform init -migrate-state`.
4. **Stop and confirm the six accounts and their emails** before applying them.
   Closing an account means 90 days suspended and roughly one closure per 30
   days at 7 accounts.
5. Apply accounts, then Identity Center assignments.
6. Add `<account>-admin` CLI profiles.

`stages/` was committed at the end of this session (`76c1473`); the stage has
never been applied.
