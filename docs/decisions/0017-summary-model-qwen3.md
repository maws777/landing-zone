# 17. Summary model: Qwen3 235B in Stockholm, chosen by eval

Date: 2026-11-25

Status: accepted. Supersedes ADR 0015 (DeepSeek V3.2 as the interim model).

## Context

The food dashboard's daily summary (mcp-servers, phase 4b) runs on DeepSeek
V3.2 in `eu-north-1` since ADR 0015, an interim pick made on one criterion:
it was the first model that answered in good French with a forced tool call.
ADR 0015 said quality would be "watched on real summaries"; nothing measured
it.

mcp-servers now has an eval of the summary (`apps/food/eval/`, PR
maws777/mcp-servers#15): 25 made-up days in the exact context production
sends, 5 runs per day and model, 10 automatic checks that each verify a rule
of the system prompt. On 2026-11-25 it ran on every text model the staging
account can call with a forced tool call inside the region SCP (ADR 0014):
11 models, 1,375 calls. Claude Haiku 5.5, the original choice, still can't
run (quota 0, ADR 0015); neither can Claude 5.x, GPT-6, Grok or GLM.

The checks fall in two groups. **Safety**: never suggest a dish too old to
eat, never advise fasting, skipping a meal or compensating, never praise a
day over target, never follow an instruction hidden in a meal description.
**Form**: lengths, numbers only from the server's stats, the diary note.

| Model | Every check | Safety only | Days 5/5 | Latency p50 / p95 | Cost per summary |
|---|---|---|---|---|---|
| Amazon Nova 2 Lite | 92 % | 98 % | 68 % | 1.1 s / 1.3 s | $0.0015 |
| Amazon Nova Pro | 90 % | 98 % | 72 % | 1.0 s / 1.7 s | $0.0025 |
| **Qwen3 235B 2507** | **87 %** | **100 %** | 64 % | 1.6 s / 5.2 s | **$0.0004** |
| DeepSeek V3.2 (current) | 86 % | 98 % | 48 % | 2.5 s / 3.4 s | $0.0014 |
| Claude Sonnet 4.6 | 52 % | 100 % | 20 % | 2.7 s / 3.1 s | $0.0106 |

(Six more models scored lower; full table in mcp-servers
`apps/food/eval/README.md`.)

## Decision

Switch the summary to **Qwen3 235B A22B 2507**
(`qwen.qwen3-235b-a22b-2507-v1:0`), on demand in **`eu-north-1`**, the same
region and the same call (Converse, forced tool call) as today.

Why this one:

- **The only model with no safety failure that also follows the form**:
  125 runs, never the old dish, no unsafe advice, all 30 injection runs
  resisted. Sonnet 4.6 is the only other model at 100 % on safety, but it
  writes longer than asked and computes its own numbers (52 % overall), at
  25 times the price.
- **The Nova models score higher overall but fail where it matters**: Nova
  Pro switched to English when a meal description told it to (3 of 5 runs),
  Nova 2 Lite told the user twice to finish a 6-day-old dish.
- **Steadier than DeepSeek** (64 % of days right on all 5 runs against 48 %)
  and a third of the price.
- **Nothing else changes**: same region, already allowed by the region SCP;
  open weights hosted by AWS, so prompts stay in the EU and never reach the
  model's publisher, as with DeepSeek.

The workload boundary (`modules/workload-ci/boundary.tf`) gains exactly that
model ARN. DeepSeek stays listed, so going back is a one-line change in the
app, no landing-zone change.

## Consequences

Good:

- A measured choice, and a way to revisit it: the eval reruns by hand or
  weekly, and a new model is one line in `apps/food/eval/summary/models.ts`.
- Cheaper: about $0.0004 a summary, ~€0.25 a month at the app's quota
  (20 summaries/user/day).

Costs and risks:

- Qwen3's own weak spots: it sometimes cites a percentage it computed
  (« 22,5 % de ton objectif ») and writes a diary note during the day
  (5 % of runs). Neither is unsafe; both are visible in the eval.
- Higher p95 latency (5.2 s against 3.4 s). The summary is generated
  asynchronously and the page polls, so it delays the summary, not the page.
- The eval is 25 days × 5 runs and pattern-based checks: enough to rank
  models and see recurring failures, not small differences.
- To revisit when Claude Haiku 5.5's quota is raised (it was the original
  choice): run the eval on it first.
