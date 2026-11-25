# Step 9: detection and auto-remediation (design)

Status: **built and demonstrated 2026-11-25** (results in ADR 0016). Agreed 2026-11-16. Michael took the three recommendations: IAM broad grants alert only, SNS email for security alerts (+ findings table), StackSet managed from management (`00-bootstrap`).

The preventive half of the guardrails is done (SCPs, steps 2, 3, 4, 6). This
is the detective half: notice a risky change shortly after it happens in any
member account, undo it when that's safe, and tell me.

## 1. What it catches (first version)

| # | Change | Event (CloudTrail) | Action |
|---|---|---|---|
| 1 | S3 bucket made public: Block Public Access removed, or a policy/ACL granting `*` | `DeleteBucketPublicAccessBlock` (the API call is `DeletePublicAccessBlock`; CloudTrail logs it under this name), `PutBucketPublicAccessBlock`, `PutBucketPolicy`, `PutBucketAcl` | Put Block Public Access back on the bucket |
| 2 | Security group open to the world on SSH/RDP | `ec2:AuthorizeSecurityGroupIngress`, `ModifySecurityGroupRules` with `0.0.0.0/0` or `::/0` on 22 or 3389 | Revoke that one rule |
| 3 | Overly broad IAM grant: a policy with `"Action": "*"` on `"Resource": "*"`, or `AdministratorAccess` attached | `iam:PutRolePolicy`, `PutUserPolicy`, `AttachRolePolicy`, `AttachUserPolicy`, `CreatePolicyVersion` | **Alert only** (decided: a wrong IAM revert can lock me out) |
| 4 | Guardrail tampering (management account) | `organizations:DetachPolicy`, `DeletePolicy`, `UpdatePolicy`; `cloudtrail:StopLogging` | **Alert only**: the break-glass path of ADR 0010 *is* a DetachPolicy, it must stay possible |

Why 3 and 4 only alert: reverting IAM or SCP changes automatically can lock
me out or fight a legitimate emergency. A wrong S3 or security-group revert
costs a minute; a wrong IAM revert can cost the account.

## 2. Architecture

```
member account (any region it acts in)          security account (eu-west-3)
  CloudTrail management event                      
    -> default event bus                            
    -> rule "lz-detect-forward"  ── PutEvents ──►  bus "lz-detection"
       (pattern: the event names above)               -> rule -> Lambda "lz-remediate"
                                                          1. classify, idempotency check
                                                          2. revert: sts:AssumeRole into
                                                             the source account's
                                                             "lz-remediation" role
                                                          3. record finding + alert
```

- **Central bus in `security`**, not in management: management keeps holding
  less (same reasoning as ADR 0009), and this is what the account is for.
- **Per-account pieces** (forwarding rule + its role, `lz-remediation` role)
  are deployed with **CloudFormation StackSets, service-managed**, targeted at
  the OUs with **automatic deployment**: a new account gets them without a
  Terraform change, and StackSets doesn't need `OrganizationAccountAccessRole`
  (locked, ADR 0010). Terraform manages the StackSet itself from
  `00-bootstrap` (management, local): decided, no delegated administrator.
- **`lz-remediation` role**: trusted only by the `lz-remediate` Lambda's role
  ARN; may do exactly the revert actions (`s3:PutBucketPublicAccessBlock`,
  `ec2:RevokeSecurityGroupIngress`, reads to confirm), nothing else.

## 3. Gotchas found while reviewing (must be handled, not discovered)

1. **IAM events only exist in `us-east-1`.** IAM is global; its CloudTrail
   events reach EventBridge in us-east-1 only. The region SCP denies
   `events:*` there for members, so the StackSet can't create the forwarding
   rule in us-east-1. Fix: a narrow SCP exception for the StackSet execution
   role (`aws:PrincipalArn` = `arn:aws:iam::*:role/stacksets-exec-*`) on
   `events:PutRule`/`PutTargets`/`DeleteRule`/`RemoveTargets` and
   `iam:PassRole` in us-east-1 only. The rule's delivery (us-east-1 ->
   eu-west-3 bus) is done by EventBridge with a role, landing in eu-west-3:
   allowed. **Verify with the policy simulator before rollout.**
2. **The org trail doesn't feed other accounts' buses.** Each account's
   default bus sees its own API calls; there's no organization-wide event
   bus. Hence the per-account forwarding rule.
3. **Loops.** The Lambda's own revert (`PutBucketPublicAccessBlock`,
   `RevokeSecurityGroupIngress`) is itself an event. Ignore events whose
   `userIdentity.arn` is the `lz-remediation` role, and make reverts
   idempotent (re-applying Block Public Access is harmless).
4. **Management account.** SCPs don't bind it and StackSets service-managed
   doesn't deploy to it: its forwarding rule (for item 4) is plain Terraform
   in `00-bootstrap`.
5. **Sandbox OU** is where the demo happens (make a bucket public, watch it
   flip back). It already has the same SCPs as everything else; nothing in
   the SCPs blocks the risky changes themselves (that's the point of
   detection), so no relaxed variant is needed for the demo.

## 4. Alerts (decided: C + A)

Decided earlier: no email/SNS (phase 3 of the app). Options:

- **A. Findings table + dashboard page.** A DynamoDB table in `security`
  (`FINDING#<time>`), shown later in a small page. Silent until I look.
- **B. Web push** through the food app's push channel (app phase 4c, not
  built yet): needs 4c first, and couples the platform to an app.
- **C. Accept SNS email for security alerts only.** Simplest and the
  industry default for "someone changed a guardrail"; it's the exception
  the earlier "no email" decision didn't consider.

Recommendation: **C now** (it's a security alert, it should interrupt me),
plus every finding written to a table (A) for the record. Move to push once
4c exists, if email gets annoying.

## 5. Cost

No fixed cost. EventBridge: AWS service events on the default bus are free;
cross-account delivery ~$1 per million events (a handful a day here). Lambda
and DynamoDB within free tier. StackSets free. SNS email: first 1,000 a
month free.

## 6. Order of work

1. `00-bootstrap`: trusted access for StackSets, CI roles in `security`
   (same two-key pattern as `network-access.tf`) and the boundary every
   role 04-detection creates must carry (same idea as ADR 0013).
2. `01-guardrails`: the us-east-1 exception for the StackSet role, Sandbox
   OU first (ADR 0006 rollout), simulator checks.
3. New stage `04-detection` (CI, in `security`): bus, Lambda, findings
   table, SNS topic, StackSet with the per-account template.
4. `00-bootstrap`: the StackSet (per-account template) and the management
   account's own forwarding rule, once the bus exists.
5. Demo in sandbox for each rule; ADR 0016.
