# 7. Centralized root access, without a delegated administrator

Date: 2026-10-07

Status: accepted

## Context

Every AWS account has a root user that can do anything in it. For the six
member accounts, each root user is identified by its own email address, but
all six addresses are `+` aliases of one inbox. Accounts created by
Organizations have no root password at first, yet whoever can read that inbox
can set one with "Forgot password" and become root of any of them. The inbox
is a single point of compromise for six accounts.

The `baseline-protections` SCP (ADR 0006) already denies every action by a
member root user signed in with long-term credentials. That limits what a
stolen root login can do, but the login itself still works, and an SCP can be
detached by anyone with enough power in the management account.

IAM offers centralized root access for organizations: the management account
can delete member root credentials and, when a root-only task comes up, open a
short `sts:AssumeRoot` session scoped by an AWS-managed task policy. Choices
to make:

- where the switch lives (which stage, local or CI);
- whether to delegate the capability to another account (IAM allows one
  delegated administrator, e.g. the `security` account);
- how the per-account deletion is done.

## Decision

**Enable both features, `RootCredentialsManagement` and `RootSessions`, from
`00-bootstrap`**, with `iam.amazonaws.com` added to the organization's
trusted-access list. Bootstrap already owns that list, and it runs locally
only (ADR 0004). Moving it to CI would mean granting the pipeline
`iam:EnableOrganizations*` for a one-time switch.

**No delegated administrator.** With one operator, delegating to `security`
would add a second account able to become root in every member account,
without anyone new to hand it to. It can be added later with
`register-delegated-administrator` when a separate security function is real.

**Delete the root credentials of all six member accounts**, one at a time,
each through an `AssumeRoot` session with `IAMAuditRootUserCredentials` before
and after, and `IAMDeleteRootUserCredentials` in between. This is a one-off
operation on each account, not a resource, so it is done with the CLI and
recorded, not modelled in Terraform. Accounts created after enabling the
feature have no root credentials to begin with.

**Break-glass:** if a root-only task appears that `AssumeRoot` can't cover, the
management account runs the "Allow password recovery" privileged task
(`IAMCreateRootUserPassword`), the inbox resets the password, the task is done,
and the credentials are deleted again.

## Consequences

Good:

- A compromised inbox no longer yields root in any member account: there is
  no password to reset.
- Root-only fixes (a bucket policy that locks everyone out) have a supported
  path that is short-lived, scoped to one task, and logged in CloudTrail as
  `AssumeRoot` from a named Identity Center user, not as an anonymous root
  login.
- Defense in depth with the SCP: one control removes the login, the other
  limits it if it ever comes back.

Costs and risks:

- Every root-level power over the member accounts now sits in the management
  account. Its own root (MFA, no keys) and the Identity Center `admins` group
  become more important. Any principal there with `sts:AssumeRoot` is
  effectively root everywhere; today that is the `AdministratorAccess`
  permission set. Roadmap step 6 is the place to narrow it.
- The management account's root user is not covered by the feature and still
  relies on its own password and MFA, and on the inbox.
- Recovery depends on the management account working. If it were lost, so
  would be the way back into member roots. Accepted: losing the management
  account is already the end of the organization.
