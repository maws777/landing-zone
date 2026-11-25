# 16. Detection and auto-remediation: central bus in security, StackSets per account

Date: 2026-11-16

Status: accepted, built and demonstrated 2026-11-25 (design: `docs/design/09-detection.md`)

## Context

Roadmap step 9: notice risky changes in any account shortly after they
happen (public S3 bucket, SSH/RDP open to the world, broad IAM grants,
guardrail tampering), revert the safe ones, alert. The preventive SCPs stay;
this is the detective half.

Constraints from earlier decisions: `OrganizationAccountAccessRole` is locked
(ADR 0010), so nothing can be pushed into member accounts through it; the
region SCP (ADR 0006) denies everything outside Paris except global services;
no Control Tower (ADR 0002).

## Decision

- **Central EventBridge bus + remediation Lambda in the security account**,
  built by a new CI stage `04-detection`. CI enters security through
  `ci/landing-zone-ci-detect-{plan,apply}` (`00-bootstrap/security-access.tf`),
  limited to `lz-*` resources; roles it creates live under `/lz/` and carry
  `platform/lz-detection-boundary`.
- **Per-account pieces** (forwarding rule and its role; the `lz-remediation`
  role the Lambda assumes) are a **service-managed CloudFormation StackSet**
  with automatic deployment to the OUs, managed from management in
  `00-bootstrap`. Trusted access enabled 2026-11-16 (Organizations service
  principal + `cloudformation activate-organizations-access`).
- **Reverts:** S3 Block Public Access and open SSH/RDP rules. **Alert only:**
  broad IAM grants and SCP/CloudTrail changes in management (a wrong IAM
  revert can lock me out; the break-glass path of ADR 0010 *is* a
  DetachPolicy).
- **Alerts:** SNS email for security alerts only, plus a findings table. An
  explicit exception to the app's "no email" choice: a guardrail change
  should interrupt me.
- **Region SCP exception for us-east-1**, because IAM's CloudTrail events
  reach EventBridge only there: `cloudformation:*` and `events:*` leave the
  home-region statement and get two of their own: denied outside
  Paris/us-east-1 for everyone, and in us-east-1 for every principal except
  `arn:aws:iam::*:role/stacksets-exec-*` (the StackSets execution role).

Applied at the root directly, not the Sandbox OU first: the region SCP is one
policy at the root, the change only lets one AWS-created role act in one more
region for two services, and every other action and principal is unchanged
(same reasoning as ADR 0014). Checked with the policy simulator after apply.

## Consequences

Good:

- New accounts get detection automatically (StackSet auto-deployment), no
  Terraform change, no admin role into the account.
- The security account holds the logic; management holds less.
- No fixed cost.

Costs and risks:

- The us-east-1 exception trusts a role *name pattern*. Anyone able to
  create a role called `stacksets-exec-*` in a member account could use
  CloudFormation/EventBridge in us-east-1. Creating such a role needs IAM
  admin in that account already; detection itself (IAM rule) alerts on it.
- If AWS renames the StackSets execution role, deployments to us-east-1 fail
  (closed, not open).
- Email is one more channel to keep tidy; revisit when the app's web push
  exists.

## Results (demo in sandbox, 2026-11-25)

Each rule triggered once for real, in sandbox (eu-west-3) or management,
then the test resource deleted. Times are from the change to the revert,
measured by polling.

| Rule | Trigger | Result |
|---|---|---|
| S3, Block Public Access removed | `DeletePublicAccessBlock` on an empty test bucket | Put back after **25 s**, finding `s3-public / reverted`, email |
| S3, Block Public Access weakened | `PutBucketPublicAccessBlock` with `BlockPublicPolicy=false` | Put back within seconds, `s3-public / reverted` |
| SSH open to the world | port 22 from `0.0.0.0/0` on a test security group | Rule revoked after **17 s**, `sg-open-admin-port / reverted` |
| IAM broad grant | `AdministratorAccess` attached to a test role | `iam-broad-grant / alerted`, email, role untouched until deleted by hand |
| Guardrail change (management) | `DeletePolicy` on a throwaway SCP attached to nothing | `guardrail-change / alerted`, email; no real SCP touched |

The Lambda ignored its own reverts (the follow-up `PutBucketPublicAccessBlock`
shows as `ignored` in its log), so no loop.

What the demo found, both fixed:

- **Wrong event name (PR #33).** The S3 call `DeletePublicAccessBlock` is
  logged by CloudTrail as `DeleteBucketPublicAccessBlock`. Every list (the
  StackSet template, management rules, bus rule, classifier and its tests)
  used the API name, so "Block Public Access removed" could never fire. The
  unit tests passed because they used the same wrong name: event names are
  now checked against a real CloudTrail event before going into a list.
- **Alert email never confirmed.** The SNS email subscription created on
  2026-11-17 was never confirmed, and AWS deletes pending subscriptions after
  three days: until 2026-11-25 every alert was dropped silently. Recreated
  (targeted local apply of `04-detection`) and confirmed. A missing
  subscription is invisible in Terraform until the next refresh; step 10's
  `lz-remediate` alarm should also check the topic has a confirmed
  subscriber.
