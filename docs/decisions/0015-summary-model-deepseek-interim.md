# 15. Summary model: DeepSeek V3.2 in Stockholm while Haiku 5.5 is unavailable

Date: 2026-11-16

Status: superseded by ADR 0017 (2026-11-25)

## Context

The food dashboard's AI summaries (mcp-servers, phase 4b) were built for
Claude Haiku 5.5 through the `eu.` inference profile (ADR 0014). On
2026-11-16, with the Anthropic use-case form submitted and the model's
Marketplace agreement `AVAILABLE`, every call from staging still failed with
"not available for this account". The cause is a quota: *Cross-region model
inference tokens per minute for Anthropic Claude Haiku 5.5* (`L-47520EB7`) is
applied at **0** in staging (and in management), against an AWS default of
10,000,000. Service Quotas refuses any request at or below the default, so
it takes a support case, with an unknown delay.

Checked the same day, from staging, in the six EU regions the region SCP
already allows for `bedrock:InvokeModel*`:

- Many open-weight models run **on demand in-region** (no profile): DeepSeek,
  Kimi, GLM, Qwen, MiniMax, Mistral's Ministral, Gemma.
- **DeepSeek V3.2** (`deepseek.v3.2`, `eu-north-1`) answered at once, in
  good French, and handles a forced tool call through the Converse API
  (structured output). The others answered "account being verified" (AWS's
  automatic check on a first use, < 2 h).
- AWS list prices in `eu-north-1` (per million tokens, input / output):
  DeepSeek V3.2 $0.74 / $2.22, Ministral 3 14B $0.24 / $0.24,
  Qwen3 235B 2507 $0.22 / $0.88, Haiku 5.5 $0.10 / $0.50. A summary is
  ~2,000 tokens in, ~300 out: from 0.03 to 0.2 cents. Price doesn't decide.

## Decision

Use **DeepSeek V3.2 in `eu-north-1`** for the summaries now, through the
Bedrock **Converse** API, so that the model is configuration (ID + region),
not code. The workload boundary (`modules/workload-ci/boundary.tf`) gains
exactly that model ARN; the region SCP is unchanged.

Keep the Haiku 5.5 support case open, and compare with Ministral 3 14B once
it's verified; switching is a Terraform variable in the app and, for a model
not listed yet, one line in the boundary.

## Consequences

Good:

- The data stays in the EU: the model is hosted by AWS in Stockholm. Only the
  weights come from DeepSeek; prompts don't leave AWS.
- No fixed cost; worst case at the app's quota (20 summaries/user/day)
  ~€1.30 a month.
- The boundary stays an explicit list of cheap models, not `bedrock:*`.

Costs and risks:

- ~6× Haiku 5.5's price per call (still a fraction of a cent).
- Model quality and tone in French aren't Claude's; watched on real
  summaries. The safety rules (data block, no tools, schema, length checks,
  text rendering) don't depend on the model.
- An open-weight model's behaviour on prompt injection may differ; the
  design assumes injection can succeed and limits what it can do (the
  summary Lambda can't write the journal), so that holds.
