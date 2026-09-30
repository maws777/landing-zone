# 6. SCP strategy: deny-lists at the root, rolled out through the Sandbox

Date: 2026-09-30

Status: accepted

## Context

Service Control Policies are the preventive guardrails of this landing zone.
Several questions come before writing any single policy:

- **Allow-list or deny-list.** An SCP setup can either remove AWS's default
  `FullAWSAccess` policy and list what *is* allowed, or keep it and add Deny
  statements for what isn't.
- **Where to attach.** At the root, everything inherits. At an OU, only that
  branch does.
- **How to roll out** without a mistake locking out real accounts.
- **What goes in first.** The roadmap listed four guardrails: deny other
  regions, deny leaving the organization, deny tampering with CloudTrail and
  its log bucket, deny root user actions. It also listed relaxed variants for
  the Sandbox OU.

## Decision

**Deny-lists on top of `FullAWSAccess`.** An allow-list must name every
service anything will ever use, and fails closed on the first thing
forgotten. With one operator and a workload still being designed, that is
constant friction for little gain. Deny-lists state the few things that must
never happen, and each one can be explained on its own.

**Attach at the root once tested.** Root attachment covers every OU and every
future account, so nothing escapes a guardrail by being created or moved
somewhere new. OU-level attachments are reserved for real differences between
OUs.

**Roll out through the Sandbox OU first.** Each new policy is attached to
Sandbox, tested from the sandbox account, then moved to the root in a second
pull request.

**First policies:**

- `baseline-protections`: deny `organizations:LeaveOrganization`; deny use of
  a member account's long-term root credentials. The root statement excludes
  `AssumeRoot` sessions (condition `Null aws:AssumedRoot = true`, AWS's
  documented pattern). That way it does not block centralized root access,
  roadmap step 3.
- `region-restriction`: deny everything outside `eu-west-3` except global
  services, using the exception list from AWS's Control Tower Region deny
  control instead of a hand-picked one.

**Deferred on purpose:**

- *CloudTrail / log bucket protection* moves to roadmap step 4. The trail and
  bucket don't exist yet, so the policy would be written against names not
  chosen yet. The trail will also live in the management account, where SCPs
  don't apply. What this SCP really protects is the log-archive bucket, and it
  belongs with that bucket.
- *Relaxed Sandbox variants* wait until there is something to relax. Neither
  policy above blocks the risky changes the detective demos need. The split
  appears when Workloads gets stricter preventive SCPs (e.g. no public S3)
  that Sandbox deliberately skips. The region restriction is one to keep in
  Sandbox: a sandbox is where forgotten resources in odd regions come from.

## Consequences

Good:

- A mistake in a new SCP hits an empty sandbox account first, not staging or
  prod. The management account is exempt from SCPs anyway, so a broken policy
  can always be fixed.
- The policies are short enough to explain line by line.
- Step 3 (removing root credentials) is already compatible with the root
  statement.

Costs and risks:

- Deny-lists only stop what someone thought of. Anything not listed is allowed
  up to the IAM ceiling. The detective controls (roadmap step 9) exist for
  what slips through.
- The region exception list is copied, so it can go stale. When a global
  service call fails with an SCP deny, check this list against AWS's current
  version first.
- `kms:*`, `config:*` and `sts:*` are exempt in AWS's list, so those services
  can be used outside `eu-west-3`. Accepted: it matches AWS's own control, and
  narrowing it is a later decision, not a guess.
- Bedrock embeddings (step 8) may need a documented cross-region exception if
  the chosen model isn't in Paris.
