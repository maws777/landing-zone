# 10. Lock OrganizationAccountAccessRole, add read-only access

Date: 2026-10-26

Status: accepted (part 1 applied with this ADR; the SCP follows in a
separate change, Sandbox OU first)

## Context

Every account Organizations creates gets `OrganizationAccountAccessRole`:
`AdministratorAccess`, trusting the management account as a whole. Any
principal in management that is allowed `sts:AssumeRole` becomes admin in
every member account, with no MFA and no Identity Center in the way. It was
the only way into a new account on day one. Since then Identity Center gives
every account a real access path (`<account>-admin`, MFA at every sign-in).

Two things still used it, both in this repo:

- `00-bootstrap`'s `aws.log_archive` provider (state bucket, CI roles in
  log-archive);
- local runs of `02-logging`.

Separately, the only permission set was `AdministratorAccess`, so every look
at any account was an admin session.

Options for the role:

- **A. Delete it in every account.** Needs admin access to each account to do
  it, and removes the fallback if Identity Center ever fails.
- **B. Narrow its trust policy** to the Identity Center admin role. Six
  AWS-created roles to import and manage, and the role stays fully usable by
  whoever matches.
- **C. An SCP that denies every action to that role** in member accounts.

## Decision

**C, a "break glass" SCP.** One statement denies `*` when
`aws:PrincipalArn` is `arn:aws:iam::*:role/OrganizationAccountAccessRole`.
The role still exists and can still be assumed, but can't do anything. It
covers accounts created later without any change. Rolled out like ADR 0006:
a separate policy on the Sandbox OU first, tested from management, then
folded into `baseline-protections` at the root, which keeps the last root
SCP slot free.

The glass can always be broken: SCPs never apply to the management account,
so detaching the policy from there restores the role. That act is a
CloudTrail event (`DetachPolicy`), which step 9 can alarm on. There is no
way to lock ourselves out.

**Replace its two uses with Identity Center profiles**, the same way the
state backend works since ADR 0009:

- `00-bootstrap`'s log-archive provider uses `profile = "log-archive-admin"`.
- `02-logging` gets a `log_archive_profile` variable for local runs; CI keeps
  assuming its own `ci/landing-zone-ci-logging-*` roles. A validation
  requires exactly one of the two.

**A read-only permission set, `ViewOnlyAccess`** (AWS-managed job-function
policy), assigned to a new `readers` group on all seven accounts. Not
`ReadOnlyAccess`: that one reads data (`s3:GetObject` on state files and
CloudTrail logs, secret values). `ViewOnlyAccess` shows what exists and how it
is configured, which is what auditing needs. The operator joins `readers` and
uses `<account>-readonly` profiles by default, admin profiles only to change
something. A `test-reader` user exists to check the group from the outside.

## Consequences

Good:

- Admin in member accounts now requires Identity Center (MFA, a group, a
  named person in CloudTrail), not just any foothold in management.
- The lock covers future accounts automatically.
- Day-to-day access is read-only, without the data.

Costs and risks:

- `00-bootstrap` now needs two Identity Center profiles (`management-admin`,
  `log-archive-admin`), and so does a local `02-logging` run. One
  `aws sso login` covers both.
- If Identity Center fails, the way in is: detach the SCP from management,
  use the role, re-attach. Slower than before, on purpose.
- `test-reader` is a real identity with a real email. It has no password
  until one is set from the console; delete it if it stops being useful.
- Identity Center lives in management, in one region (ADR 0003). A region
  outage there means no human access at all until it recovers, or the
  break-glass path above.
