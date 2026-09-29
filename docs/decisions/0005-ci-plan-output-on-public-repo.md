# 5. Full plan output in public CI logs

Date: 2026-09-29

Status: accepted

## Context

This repository is public, because it is a portfolio project. GitHub Actions
logs on a public repository are readable by anyone. The pipeline runs
`terraform plan` on every pull request, and the point of that is to review the
plan on the PR instead of in a terminal.

A Terraform plan prints resource attributes. Across this project that includes
AWS account IDs (inside every ARN), OU and organization IDs, role names, and,
if they were ever in scope, the account root email addresses.

So far the repo has kept account IDs and emails out of committed files. The
question is whether that rule has to extend to CI logs.

Options considered:

1. **Full plan in the log, sensitive values redacted.** Reviewable on the PR.
   Account IDs visible.
2. **Summary only** ("3 to add, 1 to change"), details reviewed locally.
   Leaks less, but the PR review becomes a formality.
3. **Make the repository private.** Hides everything, and removes most of the
   project's value as a portfolio piece.

## Decision

Option 1.

- Plans are printed in full in the Actions log.
- Anything genuinely sensitive is kept out of CI entirely, or marked
  `sensitive = true` so Terraform prints `(sensitive value)` instead. The root
  emails are the main case, and CI cannot read the bootstrap state that holds
  them (ADR 0004).
- Account IDs are accepted as visible. AWS's position is that account IDs are
  identifiers, not credentials, and nothing in this setup depends on one being
  secret. What stops a stranger from using the roles is the trust policy
  pinned to this repository's immutable `sub` claim, not obscurity.
- Keeping IDs out of committed files continues as tidiness, not as a control.
  This ADR is the place that says so.

## Consequences

Good:

- Plans are reviewed where the change is proposed, which is the workflow the
  pipeline exists to support.
- The security model is stated explicitly: identity and trust policies, not
  hidden identifiers.

Costs and risks:

- Account IDs make an organization easier to map for someone doing
  reconnaissance (e.g. testing which role names exist in an account). Accepted
  for a lab with no production data.
- `sensitive = true` has to be remembered for every new secret-ish variable
  or output. A missed one is printed permanently in a public log. When in
  doubt, mark it.
- Logs can be deleted per run if something leaks, but not un-seen. Treat any
  leaked credential as compromised and rotate it; don't rely on deleting logs.
