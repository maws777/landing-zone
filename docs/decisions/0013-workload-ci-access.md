# 13. How the app repository deploys into workload accounts

Date: 2026-11-06

Status: accepted (staging applied with this ADR; prod reuses the module later)

## Context

`mcp-servers` (ADR 0012) deploys into staging and prod from its own GitHub
Actions. The landing zone has to give it a way in that is:

- keyless (OIDC, like the landing zone's own CI);
- unable to reach anything but its own account, and nothing in that account
  that belongs to the platform (CI roles, the OIDC provider, its state);
- unable to grant itself more than an app needs. The app's Terraform must
  create IAM roles (one per Lambda at least), and "may create roles" is
  normally the same as "may become admin": create a role with
  `AdministratorAccess`, pass it to a Lambda, run code as it;
- unable to read the data the app stores (diet entries, user accounts, logs).

## Decision

A reusable module, `modules/workload-ci`, applied from `00-bootstrap` (local,
ADR 0004) once per workload account. Staging first.

**In the workload account:**

- **Its own GitHub OIDC provider.** CI goes straight into the workload
  account; it never passes through management, so the app pipeline and the
  landing-zone pipeline share nothing.
- **`ci/mcp-ci-plan`**: trusted for pull requests and pushes to `main` of
  `mcp-servers` only (immutable `sub` with owner and repository IDs). Reads
  configuration, never data.
- **`ci/mcp-ci-apply`**: trusted only for jobs in the repository's GitHub
  environment of the same name as the account (`staging`). Manages resources
  named `mcp-*` / `mcp/*` (ADR 0012).
- **A permissions boundary, `platform/mcp-workload-boundary`.** The apply role
  may create or change IAM roles only under `/mcp/` and only with this
  boundary attached, and may never remove it. A boundary is a ceiling: a role
  can do only what both its own policies *and* the boundary allow. So even if
  the app's Terraform attached `AdministratorAccess` to a Lambda role, the
  Lambda could still only write logs, use `mcp-*` tables, send traces and call
  Bedrock. The boundary lives under `/platform/`, which the apply role can't
  touch.
- **Data stays out of the pipeline.** Explicit denies on DynamoDB item
  actions, Cognito user actions (`Admin*`, `ListUsers*`), log reading and
  invoking the functions. The pipeline can create the table and the user pool;
  it can't read a meal, a user or a log line directly. Honest limit: it deploys
  the code that reads them, so what gets deployed is guarded by review (and in
  prod, the approval gate), not by IAM.
- **The only role CI may assume is its DNS role**, by explicit Deny. Without
  it, the apply role could create a role under `/mcp/` that trusts itself and
  assume it: in the same account, a trust policy naming a principal is enough,
  no identity-policy Allow needed. That would hand it the item access the
  boundary allows Lambdas.
- **Service-linked roles are created here**, not by CI: API Gateway's
  (`AWSServiceRoleForAPIGateway`) is made on the first API in an account and
  would otherwise need `iam:CreateServiceLinkedRole` in the pipeline.
- **Its own state bucket**, `mcp-tfstate-<account id>`, in the same account:
  versioned, SSE-S3, public access blocked, TLS only. The app's state stays
  with the app's account, and its CI never touches log-archive.

**In network:** `ci/mcp-dns-<env>-plan` and `ci/mcp-dns-<env>-apply`, trusted
by the matching role in the workload account. Apply may change only records
whose names end in `.<env>.lab.michaelteplov.com`
(`route53:ChangeResourceRecordSetsNormalizedRecordNames`), which covers the
app's endpoints and their ACM validation records, and nothing else in the
zone: not its NS records, not the other environment's names.

**Images:** one ECR repository per app per environment. Prod gets an image by
copying the exact digest that ran in staging (a job holding both roles pulls
from staging and pushes to prod), so prod never trusts the staging account.

## Consequences

Good:

- The app pipeline can't escalate, can't reach the platform, and can't read
  user data directly, and each of those is enforced by AWS (boundary, resource
  names, explicit denies), not by the workflow file.
- Prod is one more `module` block once staging works.

Costs and risks:

- Scoping by name has gaps where AWS has no names to scope: API Gateway, ACM
  and Cognito resources have random IDs, so the apply role can manage *any* of
  those in the account. Acceptable because the account holds nothing else.
- When the app needs a new AWS service, the boundary and the apply role need a
  landing-zone PR first. That friction is the point.
- Cost: free (OIDC provider, roles, boundary); the state bucket is cents.
