# 4. The bootstrap stage runs locally, never in CI

Date: 2026-09-29

Status: accepted

## Context

Every stage after `00-bootstrap` is deployed by GitHub Actions, using roles
assumed through OIDC. Those roles have to be defined somewhere, and the obvious
place is the bootstrap stage: it runs in the management account, where IAM for
the organization's top level lives, and it already exists.

That creates a loop if CI can also apply the bootstrap stage. The apply role
would be able to change the file that defines the apply role: widen its own
permissions, loosen its own trust policy, or add a second role nobody reviews.
A pull request that looks like a routine change could carry that edit, and the
pipeline would faithfully apply it. This is privilege escalation through the
pipeline, and it is a real pattern in CI compromises.

The bootstrap stage is also the one that creates, and in principle closes, AWS
accounts. Those are the least reversible operations in the project (see the
stage README: 90-day suspension, closures rate-limited).

## Decision

`00-bootstrap` is applied only from a workstation, with an Identity Center
admin session and a plan reviewed by a human. It is not in any workflow's
`paths`, and the CI roles have:

- no `iam:*` permissions at all, so they cannot modify themselves or create
  roles;
- no account creation, closure or move permissions;
- an explicit Deny on the bootstrap state object, which also keeps the account
  root emails out of CI's reach.

The CI roles, the OIDC provider and their policies live in
`stages/00-bootstrap/ci-identity.tf`. Widening what CI may do is therefore
always a local, reviewed bootstrap apply, never a side effect of a pipeline
run.

## Consequences

Good:

- The pipeline's permissions have a ceiling it cannot raise.
- The most dangerous changes (accounts, CI identity) keep a human in the loop
  by construction, not by convention.
- CI never sees the root emails.

Costs:

- Two ways of deploying exist, and the bootstrap one depends on remembering the
  README steps. Mitigated by the stage changing rarely.
- Each new stage that CI manages needs a small bootstrap change first, to add
  the permissions that stage uses. That friction is the point: it makes every
  growth in CI's power a visible, deliberate step.
- Bootstrap changes are not recorded as pipeline runs. The record is the git
  history plus CloudTrail (the org trail, roadmap step 4).
