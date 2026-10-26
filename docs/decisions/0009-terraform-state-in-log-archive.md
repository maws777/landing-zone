# 9. Terraform state moves to log-archive

Date: 2026-10-26

Status: accepted

## Context

Terraform state for every stage lives in a bucket in the management account.
That was forced on day one: `00-bootstrap` must run in management (only there
can the Organizations API be called) and it creates `log-archive`, so there was
nowhere else to put its state. ADR 0008 made `log-archive` real and gave
bootstrap a provider into it, which removes the constraint.

State is a full map of the organization: account IDs, role ARNs, policies,
and in `00-bootstrap`'s case the root email addresses. Keeping it in
management puts the map in the same account as the power to change what it
describes. Anyone who compromises management gets both at once.

Choices to make:

- how humans and CI reach a bucket in another account;
- whether the new bucket needs extra protection beyond versioning;
- how to migrate without CI and local runs disagreeing about where state is.

## Decision

**A new state bucket in `log-archive`, created by `00-bootstrap`** through
the existing `aws.log_archive` provider. Same settings as the first one
(versioning, SSE-S3, public access blocked, TLS only, `prevent_destroy`),
plus a lifecycle rule: old state versions expire after 90 days, the 10 newest
are always kept, and orphaned delete markers from `.tflock` files are cleaned
up.

**Locally, the backend uses the `log-archive-admin` Identity Center profile.**
The S3 backend takes its own `profile`, separate from the provider's
credentials. So one `terraform plan` reads state as `log-archive-admin` and
manages resources as `management-admin`. No role is created for this and no
account trusts management for it. The roadmap originally assumed a role the
bootstrap stage assumes; the backend profile does the same job with one fewer
trust relationship.

**CI uses role chaining**, same pattern as ADR 0008: two roles in
`log-archive`, `ci/landing-zone-ci-state-plan` and `-apply`, each trusting
only the matching CI role in management by exact ARN. They carry the same
rules CI had on the old bucket: read and lock every stage, write state only
from apply, explicit deny on `stages/00-bootstrap/*`. CI generates a backend
config file with the bucket name and `assume_role`. Separate roles rather than
more permissions on the log bucket roles, so each role's policy covers one
job.

**Because every caller ends up as a principal inside `log-archive`, the bucket
policy grants nothing cross-account.** It only denies non-TLS requests.
Cross-account S3 access needs both sides to say yes (the caller's IAM policy
and the bucket policy); role chaining avoids the second one entirely.

**No SCP for the state bucket, for now.** The last free SCP slot at the root
stays free, and an SCP here would have to exempt the role bootstrap manages
the bucket with, which is `OrganizationAccountAccessRole`, an admin role. It
would only stop the `log-archive-admin` session, which is the same person.
`prevent_destroy`, versioning, and the fact that a versioned bucket can't be
deleted until every version is gone cover the realistic accidents. Revisit
in step 6, once `OrganizationAccountAccessRole` is restricted and a narrower
role manages this bucket.

**Migration order**, to keep CI and local runs on the same state:

1. Local apply of `00-bootstrap`: new bucket, CI state roles, and the CI
   roles' permission to assume them. CI keeps working on the old bucket.
2. Migrate all three stages locally with `terraform init -migrate-state`.
   No merges to `main` between this step and the next.
3. A PR switches the workflow to the new bucket. Its own plans prove CI can
   read the moved state ("No changes").
4. Once verified, remove CI's access to the old bucket, then the old bucket.

## Consequences

Good:

- Compromising management no longer hands over the state. Reading it needs
  a session in `log-archive` too.
- The management account holds less, which is the direction every later
  step pushes in.
- Humans reach state through Identity Center like everything else; CI
  reaches it through roles scoped to one bucket.

Costs and risks:

- If `log-archive` became unreachable, so would all state. Recovery is
  always possible from management (`OrganizationAccountAccessRole`, or
  `AssumeRoot` for a bucket policy that locks everyone out), but it is one
  more hop than before.
- Local runs now need two SSO profiles. One `aws sso login` covers both, as
  they share the `mteplov` session.
- `00-bootstrap`'s state now sits in the account it creates. If the account
  were ever recreated, its state would have to be restored from the old
  bucket's versions or rebuilt by import. Accepted: closing `log-archive` is
  denied by SCP and its root has no credentials.
- Until CI is verified there are two state buckets and two sets of CI state
  permissions. The old ones go in a clean-up change after verification.
- The old bucket's history (every state version since day one) is deleted
  with it. A local backup was not kept: bootstrap's state holds the root
  emails, and a copy on disk is what this move is meant to avoid.

Update 2026-10-26: migration verified (PR #12, CI "No changes" on both
stages); old bucket and `ci_state` removed the same day.
