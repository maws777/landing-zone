# 2. Build the landing zone in Terraform, not Control Tower

Date: 2026-09-24

Status: accepted

## Context

AWS Control Tower sets up a landing zone for you. It creates the organization,
an OU structure, a log archive and audit account, an org-wide CloudTrail,
Identity Center, and a catalogue of guardrails, in something like an hour of
clicking. For a company standing up a new AWS estate it is usually the right
answer, and saying otherwise in an interview would be wrong.

The alternative is assembling the same pieces in Terraform: `aws_organizations_*`
for the OUs and accounts, hand-written SCPs, `aws_ssoadmin_*` for Identity Center
assignments, an org trail, a state bucket.

What makes this decision go the other way is what the project is *for*. Nobody
is paying me for a landing zone; the artifact is the understanding, and the
evidence of it. A Control Tower landing zone demonstrates that I can follow a
wizard. It also hides exactly the mechanisms worth being able to explain: what an
SCP evaluates against, why it cannot grant permissions, why it does not apply to
the management account, what a permission set becomes inside a member account.

Cost matters too. Control Tower itself has no charge, but it switches on the
services its guardrails need — AWS Config recording in every account and region
it governs, plus CloudTrail — and Config bills per configuration item recorded.
On a €10–15/month budget that is a real fraction of the total, spent on
detective controls I have not chosen and may not want yet.

## Decision

Build the landing zone myself in Terraform. Do not use Control Tower.

Enable detective services such as Config, GuardDuty and Security Hub later,
deliberately and selectively, where a specific control justifies the cost.

## Consequences

Good:

- Every OU, account, policy and assignment exists because I wrote it, so I can
  explain all of it. That is the deliverable.
- The whole landing zone is in version control, reviewable in a pull request, and
  reproducible from an empty organization.
- Cost stays under my control: nothing gets switched on because a guardrail
  bundle wanted it.
- No Control Tower drift model to work around. Control Tower expects to own its
  resources and reports out-of-band changes as drift, which makes mixing it with
  Terraform awkward; there is nothing to mix here.

Costs and risks:

- Considerably more work, and the work is mine to get right. Control Tower's
  guardrails encode AWS's accumulated experience of what people get wrong; I am
  reimplementing a subset of that from documentation.
- No AWS-maintained upgrade path. When AWS adds a recommended control, Control
  Tower users get an update to apply and I get a blog post to read.
- Account provisioning is a bare `aws_organizations_account` rather than Account
  Factory — no baseline automatically applied to new accounts. Acceptable for
  seven accounts created once.
- Some enterprise job descriptions name Control Tower directly. Being able to
  explain why I did not use it, and what it would have done for me, is the
  mitigation — which is what this record is for.
