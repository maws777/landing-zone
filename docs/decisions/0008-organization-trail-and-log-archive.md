# 8. Organization trail delivering to an Object Lock bucket in log-archive

Date: 2026-10-16

Status: accepted

## Context

Nothing records API activity across the organization yet. Roadmap step 4 adds
an organization-wide CloudTrail trail. It is the evidence trail for every
later control: the detective Lambdas (step 9) read it, and an incident review
starts from it. Evidence is only useful if the people it records can't
change it. That rules out keeping it in the account it describes, and it
rules out a bucket that an admin can quietly empty.

The `log-archive` account (Security OU) exists for this. Choices to make:

- where the trail is created and managed (management, or delegated to
  `security`);
- how logs are protected from deletion, and for how long;
- how they are encrypted;
- how CI, which today only works in the management account, gets into
  `log-archive` to manage the bucket.

## Decision

**One organization trail, created in the management account.** It covers
every region, so calls to global services (logged in `us-east-1`) and calls
the region SCP denies elsewhere are recorded too. It logs management events
(read and write) and nothing else: no data events, no Insights, no CloudTrail
Lake. Log file validation is on: CloudTrail writes a signed digest file every
hour, and `aws cloudtrail validate-logs` proves later that no log file was
changed or removed. No delegated administrator for now, for the same reason
as ADR 0007: one operator, and an org trail stays owned by the management
account even when another account manages it.

**The bucket lives in `log-archive`:**

- **S3 Object Lock in governance mode, 365-day default retention.** Each log
  object can't be deleted or overwritten for a year. Governance mode lets a
  principal holding `s3:BypassGovernanceRetention` override it; compliance
  mode would stop even root and can never be shortened. Compliance is the
  real-world choice for regulated logs, but on a learning setup a mistake in
  compliance mode is a year of storage nobody can remove. The SCP in this
  step denies the bypass permission in member accounts, which brings
  governance close to compliance without the trap.
- **Lifecycle expiry after the retention ends**, so storage stops growing.
- **SSE-S3 encryption.** A customer-managed KMS key would add access control
  over decryption and its own audit trail, at about $1/month fixed. Same
  trade-off as the state bucket; revisit if the threat model asks for it.
- **Only CloudTrail can write**, and only for our trail: the bucket policy
  grants `cloudtrail.amazonaws.com` access with `aws:SourceArn` pinned to the
  trail's ARN. Without that condition, any trail in any AWS account could be
  pointed at this bucket (the confused deputy problem). Non-TLS requests are
  denied, ACLs are disabled (`BucketOwnerEnforced`), and public access is
  blocked.

**Cross-account access for CI: narrow roles in `log-archive`, created by
bootstrap (option B).** `00-bootstrap` gets a second provider that reaches
`log-archive` through `OrganizationAccountAccessRole` (local runs only,
ADR 0004). It creates two roles there, `landing-zone-ci-plan` (read-only) and
`landing-zone-ci-apply` (manage the log bucket only). Each trusts only the
matching CI role in management. The rejected option A was letting CI assume
`OrganizationAccountAccessRole` directly. That is full admin in the account
that holds the evidence, from a pipeline.

**CI still gets no `iam:*`.** Creating an organization trail needs the
CloudTrail service-linked role in management. Bootstrap creates it, so the
pipeline never needs IAM permissions to make one.

**New stage `02-logging`, run by CI.** It contains the bucket (log-archive
provider) and then the trail (management provider), in one stage, so the
dependency between them is explicit.

**SCP, added to `01-guardrails` once the bucket exists:** deny changing the
log bucket's policy, Object Lock configuration, lifecycle, versioning or
public access block, deny deleting it, and deny `s3:BypassGovernanceRetention`,
for everyone in member accounts except the log-archive CI apply role. Member
accounts can't stop or change the organization trail anyway, because only the
management account can, so the SCP protects the bucket, not the trail.

## Consequences

Good:

- Every API call in every account and region lands in one place that the
  recorded people can't alter, with cryptographic proof of integrity.
- Cost is close to zero: the first copy of management events is free;
  S3 storage and PUT requests for one person's activity are cents a month.
- The pipeline reaches the evidence account through a role that can manage
  one bucket, not through an admin role.
- This unlocks step 5 (state bucket into `log-archive`) and step 9
  (detection reads these events).

Costs and risks:

- The trail itself sits in the management account, where SCPs don't apply.
  Anyone with admin there can stop logging. Mitigation: `StopLogging` and
  `DeleteTrail` become alarm-worthy events in step 9, and step 6 narrows
  who is admin in management.
- Governance mode is weaker than compliance mode. Anyone holding the bypass
  permission in log-archive could delete logs early. The SCP closes that for
  principals in member accounts. Whether it also stops an `AssumeRoot`
  session's `S3UnlockBucketPolicy` task gets tested when the SCP is written.
- Bootstrap now manages resources in a second account. Its local apply
  needs an admin session that can assume into `log-archive`.
- A year of logs can't be removed early. Deleting the bucket before then
  is not possible by design.
