# Session log

Running notes on what happened when, so picking the work back up doesn't mean
re-deriving where things stood. Newest session first.

---

## Resume here (updated 2026-09-29, end of session)

Read this block first; the entries below have the detail if needed.

**State of the world: bootstrap stage complete (pillar 1, pre-roadmap).**

- Organization `o-zwsk12p8wd` (root `r-tmym`), imported. Trusted access:
  `sso` + `cloudtrail`. Feature set ALL, SCP type enabled, **no SCPs yet**.
- 4 OUs, 6 member accounts (7 of 10 quota), each in its OU. `admins` group has
  `AdministratorAccess` on all of them via Identity Center.
- Terraform state in **S3** with native locking. Bucket name in gitignored
  `backend.hcl`. No local state left.
- CLI profiles `<account>-admin` for all six accounts, sharing the `mteplov`
  SSO session. One `aws sso login` covers them all.
- Provider pinned with `allowed_account_ids`; real IDs only in gitignored files.
- No long-lived AWS credentials anywhere on the machine.

**To start a session**

```powershell
aws sso login --profile management-admin
cd stages/00-bootstrap
$env:AWS_PROFILE = "management-admin"
terraform init "-backend-config=backend.hcl"   # only on a fresh clone
terraform plan    # expect: No changes
```

**Next: roadmap step 1, CI/CD identity (GitHub OIDC).** Start with the parked
questions below, and the ADR on whether bootstrap runs in CI.

**Gotchas learned**

- PowerShell splits unquoted `-flag=a.b` at the dot → quote it. Applies to
  `-target=`, `-out=`, `-backend-config=`, anything with a dot in the value.
- A command that `cd`s leaves the shell there; run git from the repo root.
- The Organizations quota is only readable in `us-east-1`.
- Plan files contain account details in plaintext; `*.tfplan` is gitignored,
  delete after apply anyway.

**Open, not blocking:** whether to keep the `Co-Authored-By: Claude` trailer on
commits. Keeping it for now; if dropped, rewrite history + force-push `main`.

**Parked for CI/CD (roadmap step 1):** first role applied locally; bootstrap
local-only vs in CI (ADR); public Actions logs would leak IDs/emails; bucket
name via `-backend-config` from a GitHub variable. Details in CLAUDE.md step 1.

**Idea parked (2026-09-29): note-taking MCP.** The MCP server could become
a note tool I write to and search through Claude, including claude.ai on the
web. That would answer the corpus question. It raises three questions for later
ADRs: write tools make prompt injection more dangerous (use scoped tokens, no
hard-delete, keep versions); an always-on tool conflicts with deploying the app
only for demos (always-on cheap core + demo stack?); and whether I also want my
own web UI. Details are in CLAUDE.md roadmap step 8. Don't start until the
landing zone is done.

---

## 2026-09-29 — bootstrap finished: OUs, bucket, state migration, accounts

### Done

**OUs and state bucket.** Targeted plan (9 to add), saved with `-out`,
applied from the file, file deleted. Verified in AWS independently of
Terraform: versioning Enabled, AES256, all four public-access-block flags,
TLS-only bucket policy, four OUs under the root.

**Bug caught in the README before it bit.** The old step 2 targeted only
`aws_s3_bucket.state`. `-target` pulls in a resource's *dependencies*, not its
*dependents*. Versioning, encryption, the public access block and the policy
all reference the bucket, so they'd have been skipped, and state would have
been migrated into a bare bucket. The README now lists all five bucket
resources.

**State migrated to S3.** The backend uses a *partial configuration*:
`backend.tf` (committed) has everything except `bucket`, which comes from the
gitignored `backend.hcl` via `-backend-config`. That's because the bucket name
contains the management account ID and the repo is public. The local state was
backed up first, then `terraform init -migrate-state -force-copy`. Verified:
`state list` reads from S3, and the bucket holds the state object. The `.tflock`
object appears only in the version history, meaning the lock was taken and
released. The re-plan showed exactly the remaining 12 resources. Stale local
state files deleted afterwards.

**Six accounts + Identity Center assignments.** Quota rechecked (10, 1 used).
The saved plan showed each account's real OU ID, checked against the mapping.
Apply: 12 added, accounts took 11–58 s each. Final `terraform plan`: `No changes`.

**CLI profiles.** Six `<account>-admin` blocks in `~/.aws/config`, all
verified with `get-caller-identity`. Each account's role got a different random
suffix (`AWSReservedSSO_AdministratorAccess_<suffix>`), confirming that anything
referencing these roles must use a wildcard, not a literal name.

### Decisions and discussions

- **Admin on every account is deliberate, for now.** One operator, everything
  still to build, no CI yet. The end state is read-only for humans in prod and
  log-archive, admin in sandbox, and emergency-only admin elsewhere. The steps
  that get there: SCPs cap admins (step 2), CI/CD removes the need for human
  writes (step 1), and a read-only permission set (step 6).
- **Adding people later** means Identity Center users in their own groups with
  narrow permission sets, never new accounts and never `admins`. Account root
  emails are per *account*, not per person; the `+aws-` pattern is only a
  convenience.
- **Parked:** CI/CD open questions and the note-taking MCP idea (see Resume
  block and CLAUDE.md).
- **Working agreement:** every action now starts with a briefing (where we are
  in the architecture, what it does, what to remember). Recorded in CLAUDE.md.

### Gotchas

- `-out=x.tfplan` fails the same way `-target=a.b` does in PowerShell ("Too
  many command line arguments"). Quote any flag whose value contains a dot.
- `"-chdir=$d"` needs the quotes for PowerShell to expand the variable.

---

## 2026-09-25 — root key revoked, credentials pinned, org import applied

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

Reviewed and confirmed against the expectations written down last session:
imported not created, `cloudtrail` added, `sso` untouched, nothing destroyed.
Pushed as `e008ae6`.

### Applying now: organization import only

Scope is deliberately just `aws_organizations_organization.this`, with no OUs,
no state bucket and no accounts. The plan is saved with `-out` and applied from
that file, so exactly the reviewed actions run and nothing that changed in
between. Stop after this apply.

State is still **local** (`terraform.tfstate` in the stage folder, gitignored)
until the S3 bucket exists and the migration runs. Don't delete it: it's
now the only record that Terraform manages the organization.

**Result:** `1 imported, 0 added, 1 changed, 0 destroyed`. Verified outside
Terraform: `list-aws-service-access-for-organization` returns `cloudtrail` and
`sso`, and the `management-admin` SSO login still works. A re-plan shows
`No changes`. `terraform state list` holds only the organization. The plan file
was deleted after apply (plan files contain account details in plaintext);
`*.tfplan` is now gitignored.

### Next

Step 2 of the bootstrap sequence: plan and apply the four OUs + state bucket,
then migrate state to S3.

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
