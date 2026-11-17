# 04-detection

Roadmap step 9, the detective half of the guardrails (design:
`docs/design/09-detection.md`, ADR 0016). Runs in CI, in the **security**
account.

What it creates:

| Resource | Purpose |
|---|---|
| Event bus `lz-detection` | Every account forwards a short list of risky CloudTrail events here. Its policy accepts `PutEvents` from this organization only. |
| Rule `lz-to-remediate` | Sends those events to the Lambda. |
| Lambda `lz-remediate` (Python, `lambda/remediate.py`) | Classifies the event, reverts S3 public access and SSH/RDP open to the world through each account's `lz/lz-remediation` role, alerts on IAM broad grants and guardrail changes. |
| Table `lz-findings` | One item per event (also the idempotency record: EventBridge delivers at least once). 90-day TTL. |
| Topic `lz-security-alerts` + email subscription | The alert. AWS emails a confirmation link first. |

What it doesn't create: the per-account pieces (forwarding rule and its role,
`lz-remediation` role). Those are a service-managed StackSet in
`00-bootstrap`, so new accounts get them automatically.

## Run

CI: like every stage (plan on PRs, apply on `main` after approval). Needs the
`ALERT_EMAIL` repository secret.

Locally:

```powershell
cp terraform.tfvars.example terraform.tfvars   # then fill it in
terraform init "-backend-config=backend.hcl"
$env:AWS_PROFILE = "management-admin"           # the default provider only reads the organization
terraform plan
```

Tests for the classifier (stdlib only):

```powershell
python -m unittest discover -s stages/04-detection/tests
```

No fixed monthly cost: Lambda, DynamoDB on demand and SNS email stay in their
free tiers at this volume.
