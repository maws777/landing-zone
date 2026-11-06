# 11. DNS: delegate lab.michaelteplov.com to Route 53 in the network account

Date: 2026-11-06

Status: accepted, applied (PR #17, delegation verified the same day)

## Context

The app (roadmap step 8) needs names of its own: the MCP endpoint, the
dashboard, and the DNS records ACM uses to validate their certificates.
`michaelteplov.com` is registered at GoDaddy, which also hosts its DNS.

Options for where the app's names live:

- **A. Move the whole domain's DNS to Route 53** (point the domain's name
  servers at AWS). Everything under `michaelteplov.com`, including anything
  unrelated to this project, would then depend on this AWS setup.
- **B. Delegate one subdomain**, `lab.michaelteplov.com`, to a Route 53 zone.
  GoDaddy keeps the domain and its other records; four NS records named `lab`
  hand that subtree to AWS.
- **C. Register a new domain in Route 53.** Clean, but a yearly fee for a
  second domain, and the portfolio is easier to show on my own name.

And which account holds the zone: management (holds as little as possible
since ADR 0009), a workload account (staging or prod would own a name both
use), or network (the account set aside for shared plumbing).

## Decision

**B, in the network account.** A public hosted zone for
`lab.michaelteplov.com`, stage `03-dns`, deployed by CI like `01-guardrails`
and `02-logging`.

- CI reaches network through `ci/landing-zone-ci-dns-{plan,apply}`, created by
  `00-bootstrap` (`network-access.tf`) and each trusted only by the matching
  management CI role. Route 53 only. The apply role can create zones and
  change records, but an explicit Deny keeps `DeleteHostedZone` out of the
  pipeline.
- The zone has `prevent_destroy`. Route 53 gives each new zone a random set of
  four name servers, so losing the zone means redoing the delegation at
  GoDaddy by hand, and every `lab.` name is down until then.
- The VPC half of roadmap step 7 (shared VPC, NAT, endpoints) is deferred with
  the optional ECS stack: the serverless core runs outside any VPC.

## Consequences

Good:

- The blast radius stays small: only `lab.` depends on AWS, and the rest of
  the domain is untouched.
- Route 53's four name servers sit on four different TLDs (`.com`, `.net`,
  `.org`, `.co.uk`), so even a registry outage leaves the zone reachable.

Costs and risks:

- $0.50/month for the zone, plus $0.40 per million queries: the project's
  first fixed cost beyond the free foundation.
- **The GoDaddy account is now part of the security boundary.** Whoever
  controls it can repoint `lab` at their own name servers and then pass ACM's
  DNS validation for any `lab.` name. It needs MFA, like the AWS root users.
- No DNSSEC. Signing needs a KMS key in `us-east-1` ($1/month) and a DS record
  at GoDaddy; not worth it for a lab subdomain yet.
- Open for step 8: the app's certificates will live in staging/prod, while
  their validation records live here in network. Either the app's stage writes
  records through the DNS roles, or `staging.lab` / `prod.lab` get delegated
  again to zones in those accounts. Decide when the app is built.
