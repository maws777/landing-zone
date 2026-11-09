# 14. Bedrock: allow model calls in six EU regions, not only Paris

Date: 2026-11-09

Status: proposed

## Context

The food app's dashboard (roadmap step 8, phase 4) shows a short summary of
the day written by Claude Haiku on Bedrock. The `region-restriction` SCP
(ADR 0006) denies every action outside `eu-west-3`, except global services.

Checked on 2026-11-09 from the staging account:

- `anthropic.claude-haiku-5-5` in `eu-west-3` supports only
  `INFERENCE_PROFILE` calls: it can't be called directly in Paris.
- The `eu.anthropic.claude-haiku-5-5` geo inference profile runs a request in
  any of `eu-north-1`, `eu-west-3`, `eu-south-1`, `eu-south-2`, `eu-west-1`,
  `eu-central-1` (Bedrock picks one per request, by available capacity).
- AWS documents that a cross-region inference call fails if an SCP denies any
  of the profile's destination regions, even when the request would have
  landed in an allowed one.

So with the SCP as it is, the summary can't work at all.

Options:

- **A. Exempt `bedrock:*` from the region rule**, like a global service. One
  line, but it allows every Bedrock action (agents, knowledge bases, model
  customization) in every region in the world.
- **B. Exempt only the two invoke actions, and hold them to the EU** with a
  second deny statement. Two statements instead of one.
- **C. Use the `global.` profile.** Routes worldwide: health data (GDPR
  Article 9, see the threat model) could be processed outside the EU.
- **D. Skip AI summaries.** The rest of the dashboard doesn't need them.

## Decision

**B.** In `stages/01-guardrails/scp-region.tf`:

1. `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` join the
   actions the home-region deny skips.
2. A new statement `DenyBedrockOutsideEU` denies exactly those two actions
   when `aws:RequestedRegion` isn't one of the six regions above.

Every other action keeps the Paris-only rule. Which identities may call a
model at all is decided elsewhere: the workload boundary
(`modules/workload-ci/boundary.tf`) already lists the two actions, and only
the summary Lambda's role will carry them (phase 4).

Rolled out at the root directly, not Sandbox first (ADR 0006's pattern): the
change only removes a denial for two actions and adds a narrower one for the
same two, so for every other action the policy is unchanged and nothing can
break. Checked after apply with the IAM policy simulator, which evaluates
SCPs: `bedrock:InvokeModel` allowed in `eu-central-1`, denied in `us-east-1`,
and an unrelated action (`dynamodb:ListTables`) still denied in `eu-central-1`.

## Consequences

Good:

- Data stays in the EU. The data-residency reason for the region rule holds;
  only "Paris" becomes "the EU" for one kind of request.
- Narrow: no Bedrock configuration outside Paris, and the SCP stays one
  policy (4 of 5 attachment slots at the root, unchanged).

Costs and risks:

- The region list is a copy of AWS's routing table. If AWS adds a region to
  the `eu.` profile, calls start failing (fail closed, not open). Re-check
  with `aws bedrock get-inference-profile` when the model changes or a call
  is denied.
- Any member account may now invoke models in the six regions, not only
  staging/prod. Identity policies still decide who can, and the sandbox
  account is the obvious place where that matters; acceptable for a lab.
