# modules/workload-ci

What an app repository needs to deploy into one workload account (staging or
prod) by itself, and nothing more. Used from `stages/00-bootstrap`
(`workloads.tf`), applied locally (ADR 0004). Design and trade-offs:
[ADR 0013](../../docs/decisions/0013-workload-ci-access.md); naming
conventions: [ADR 0012](../../docs/decisions/0012-mcp-platform-layout.md).

## What it creates

| Resource | Account | Notes |
|---|---|---|
| GitHub OIDC provider | workload | App CI goes straight in, never through management |
| `ci/mcp-ci-plan` | workload | Trusted for PRs and `main` of the app repo. Reads configuration, never data |
| `ci/mcp-ci-apply` | workload | Trusted only for jobs in the app repo's GitHub environment named like the account. Manages `mcp-*` / `mcp/*` |
| `platform/mcp-workload-boundary` | workload | Permissions boundary every role the app creates must carry |
| `mcp-tfstate-<account id>` | workload | The app's state. Keys must be `<stack>/terraform.tfstate` |
| `AWSServiceRoleForAPIGateway` | workload | Created here so CI never needs `iam:CreateServiceLinkedRole` |
| `ci/mcp-dns-<env>-plan`, `-apply` | network | Apply may only write record names matching `dns_record_patterns` |

Cost: free, plus cents for the state bucket.

## The rules, and how they are enforced

| Rule | Mechanism |
|---|---|
| App roles can't exceed the platform's ceiling | `iam:PermissionsBoundary` condition on role creation and policy changes; `DeleteRolePermissionsBoundary` denied |
| CI can't touch the platform | Allows only on `/mcp/` paths; explicit Deny on `role/ci/*`, `policy/platform/*`, the OIDC provider |
| CI can't read user data directly | Explicit Deny on DynamoDB items, Cognito `Admin*` / `ListUsers*`, log reading, invoking functions |
| CI can't borrow another role | Explicit Deny on `sts:AssumeRole` for everything but its DNS role |
| CI can't touch other names in the zone | `route53:ChangeResourceRecordSetsNormalizedRecordNames` with `ForAllValues:StringLike` |

## Checking it

The IAM policy simulator evaluates a role's real policies without doing
anything. Pass `aws:RequestedRegion`: without it the region SCP denies every
regional action, and the result looks like a bug in the role.

```powershell
$a = aws sts get-caller-identity --profile staging-admin --query Account --output text
aws iam simulate-principal-policy --profile staging-admin `
  --policy-source-arn "arn:aws:iam::${a}:role/ci/mcp-ci-apply" `
  --action-names dynamodb:GetItem `
  --resource-arns "arn:aws:dynamodb:eu-west-3:${a}:table/mcp-food" `
  --context-entries "ContextKeyName=aws:RequestedRegion,ContextKeyValues=eu-west-3,ContextKeyType=string" `
  --query 'EvaluationResults[0].EvalDecision'
# expect: explicitDeny
```
