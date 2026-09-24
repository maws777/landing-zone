# 3. IAM Identity Center as a Single-Region instance in eu-west-3

Date: 2026-09-24

Status: accepted

## Context

When enabling IAM Identity Center, the console offered two shapes:

- **Single-Region**, with all identity data held in the chosen region.
- **Multi-Region**, replicating identity data to a second region — the offer here
  was Oregon, `us-west-2`.

Multi-Region buys availability. Identity Center is the only sign-in path for
every human in this organization, so if its region is unreachable, so is all
normal access.

Two things push the other way.

First, data location. The directory holds usernames, group memberships and
credentials for real people. Keeping that in the EU is the simpler position to
hold and to explain, and replicating it to Oregon is a decision that would need
justifying rather than accepting by default.

Second, and more practically: a region-restriction SCP is planned, denying
everything outside `eu-west-3`. Those policies are already fiddly — they need
carve-outs for global services that only have endpoints in `us-east-1`, such as
IAM, Organizations, Route 53 and CloudFront. Adding an identity service that
legitimately operates in Oregon means another exception, and every exception in a
deny policy is a place for a mistake to hide. A single-region instance keeps that
policy closer to "deny everything that is not Paris, except the documented
global-service list".

## Decision

Enable Identity Center as an organization instance, Single-Region, in
`eu-west-3`.

Revisit if availability becomes a real problem, and if so replicate to a second
**EU** region such as Ireland (`eu-west-1`) rather than to the US — recorded as a
new decision with the SCP exception it requires.

## Consequences

Good:

- Identity data stays in the EU.
- The region-restriction SCP has one fewer exception, so it is easier to write
  correctly and easier to review.
- Single-region means one place to look when something is wrong with sign-in.

Costs and risks:

- **A regional outage in `eu-west-3` makes the sign-in portal unreachable**, and
  the fallback is the root user of the management account — MFA-protected, rarely
  used, and therefore exactly the credential most likely to be awkward in a
  hurry. The mitigation is knowing that in advance: root credentials and MFA
  device must be recoverable, because this is the path they exist for.
  Acceptable for a lab; it would need a different answer for anything with an
  availability commitment.
- Switching to Multi-Region later is a change to the instance, not a
  configuration toggle, so this is not a free decision to reverse.
- Latency for a user outside Europe is slightly worse. Irrelevant here — there
  is one user, in Europe.
