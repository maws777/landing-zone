# Step 10: observability (design)

Status: draft, 2026-11-25. Decision 1 taken (alerts by SNS email, never through the app); decisions 2 and 3 open (section 7).

Roadmap step 10 says: CloudWatch dashboards and alarms, an SLO, a k6 load
test with cost results. This is the plan for doing that on what was actually
built, which drifted from the original plan in ways that change the design
(section 1).

## 1. What changed since the roadmap was written

| Original plan | What exists | Consequence for step 10 |
|---|---|---|
| Staging, then prod | Only staging, used every day from claude.ai and the iPhone | Staging *is* production here. The SLO and alarms go on staging; a prod copy inherits them when it exists. |
| Container image, optional Fargate stack | Zip packages, no container, Fargate undecided | The load test targets the serverless API only. |
| App alarms by iPhone web push (phase 4c), no email | Phase 4c not built. Step 9 accepted **SNS email for security alerts** (ADR 0016) | Decided: alarms go by **SNS email**, permanently. The food app is not an alerting app, so phase 4c no longer carries alarms. |
| Rate limiting as a defence | API Gateway throttle **3 rps, burst 10**, summaries capped at 20/user/day | A load test mostly measures the throttle. That's a result worth showing (the cost-abuse defence works), not a problem. Decision 2. |
| Haiku-class summary model | Qwen3 235B (ADR 0017), and an eval of the summary in mcp-servers | Model quality is now measurable. Decision 3. |
| Budget created by hand on Day 0, "to Terraform later" | Still manual | Moves to Terraform here, as the cost alarm. |

## 2. What we watch, and why

Three questions, one dashboard each answers:

1. **Is the app working for me?** (MCP endpoint and dashboard API)
   API Gateway: requests, 4xx, 5xx, 429 (throttled), latency p50/p95/p99.
   Lambda (MCP, dashboard, summary): errors, duration p95, throttles, init
   duration (cold starts). DynamoDB: throttled requests, latency.
2. **Is the AI part behaving?** Summary outcomes (`generated`, `fresh`,
   `quota`, `invalid`, `error`), model latency, tokens in/out, from the
   structured logs we already write (`model_call`, `summary`), shown with
   Logs Insights widgets. No custom metrics, so no metric cost.
3. **Is the platform's safety net alive?** The detection Lambda
   (`lz-remediate`, security account): errors, invocations, findings written.
   A detection system that fails silently is worse than none.

Nothing new is logged: the existing logs already have tool names, outcomes,
status codes and token counts, never meal content.

## 3. The SLO

**Scope:** the food app's HTTP API as a whole: the MCP endpoint (what I use
every day through Claude) and the dashboard's `/api/*` share it. API Gateway's
free metrics are per API; per-route metrics would be paid custom metrics, and
the two routes run on the same gateway, so one SLO covers both.

- **SLI 1, availability:** share of requests that don't end in a 5xx,
  from API Gateway metrics. Throttled requests (429) and auth refusals (401)
  are the system working as designed and don't count against it.
- **SLI 2, latency:** share of requests answered in under 1 s at the API
  Gateway (cold starts included: that's what Claude experiences).
- **Objectives:** 99.5 % availability and 95 % under 1 s, over a rolling
  30 days. 99.5 % leaves an error budget of ~3.6 h a month, honest for a
  single-region serverless app with no redundancy beyond what AWS gives.
- **Alerting on the error budget, not on single errors:** burn-rate alarms,
  the method from Google's SRE workbook. A fast burn (budget gone in about
  2 days: 14.4× the allowed error rate over 1 h) alerts at once; a slow burn
  (6× over 6 h) alerts too. One bad request at 3 a.m. does nothing; a broken
  deploy alerts within the hour. Metric math alarms on API Gateway's
  `5XXError` and `Count`, no custom metric.

The SLO is written down in a short doc (target, SLIs, how they're computed,
what happens when the budget is spent: stop feature work, fix reliability).

## 4. Alarms

About ten, inside CloudWatch's free tier (10 alarm metrics; above that,
$0.10 per metric a month):

| Alarm | Account | Why |
|---|---|---|
| SLO fast burn, slow burn | staging | The two that matter for users |
| Lambda errors (MCP, dashboard, summary) | staging | Code exceptions, one per function |
| DynamoDB throttles | staging | On-demand shouldn't throttle; if it does, something is wrong |
| Summary `invalid` or `error` outcomes | staging | The model answered badly or not at all (log metric filter) |
| `lz-remediate` errors | security | The detection Lambda failing |
| Monthly budget (actual and forecast) | management | Cost, replaces the Day 0 manual budget (AWS Budgets, 2 budgets free) |

Where they go: decision 1.

## 5. Load test (k6)

What it should show, in one page of results:

- **Latency under normal use:** p50/p95 of the main tools at a steady rate
  under the throttle (e.g. 2 rps for 5 minutes), cold starts separated out.
- **The rate limit works:** above 3 rps, API Gateway answers 429, Lambda is
  never invoked for those requests, and the cost stays flat. That is the
  cost-abuse defence from the threat model, measured.
- **The summary quota works:** the 21st summary request of the day returns
  `quota` and never calls Bedrock.
- **Cost:** for each scenario, requests, Lambda GB-seconds, DynamoDB
  request units and API Gateway calls read from CloudWatch afterwards,
  turned into a cost per 1,000 tool calls and a projected month at my usage
  and at 10× / 100×.

How:

- k6 runs on my machine (installed like Terraform: official release,
  checksum checked). Scripts in `mcp-servers/loadtest/`, results committed.
- A dedicated Cognito user `loadtest` in the staging pool, so its writes sit
  in their own partition (tenant isolation already guarantees I never see
  them) and are deleted afterwards. k6 gets a token through the normal
  OAuth flow, done once by hand; no new auth path.
- Never against Bedrock in volume: the summary scenario only proves the
  quota (21 requests).
- Decision 2: stay under the production throttle, or raise it temporarily.

## 6. Order of work

1. **mcp-servers:** `infra/monitoring.tf`: the dashboard (questions 1 and 2),
   the staging alarms, the log metric filter for summary outcomes. CI can
   already create `mcp-*` alarms and dashboards (`modules/workload-ci`).
2. **landing-zone:** the alert channel (decision 1). If it's SNS email: the
   CI role's permissions gain SNS on `mcp-*` topics; one topic per
   environment.
3. **mcp-servers:** SLO doc and the two burn-rate alarms.
4. **mcp-servers:** k6 scripts, the `loadtest` user, a run, results with
   costs.
5. **landing-zone:** the budget in Terraform (`00-bootstrap`, management,
   local) and the `lz-remediate` alarm (`04-detection`, CI). Import the
   Day 0 budget instead of creating a second one.
6. Decision 3, if yes: the eval role.

Each lot: plan shown, applied after confirmation, verified (an alarm forced
into `ALARM` once with `set-alarm-state` to see the notification arrive).

## 7. Decisions

1. **Alert channel. Decided 2026-11-25: SNS email**, and it stays that way.
   Michael: email is the traditional channel for operational alarms, and the
   food app shouldn't become the alarms app. So the alarm part of phase 4c
   (alarm → push Lambda → iPhone) is dropped; web push, if built, is only
   for the app's own nudges. One SNS topic per environment, email
   subscription (AWS sends a confirmation link first: click it, or nothing
   arrives, as step 9 found).
2. **Load test throttle.**
   - **A. Under the production throttle** (recommended): nothing changes in
     the live config; the results show the latency at normal use and the
     throttle doing its job.
   - B. Raise the throttle for one test run to find Lambda's own limits, then
     put it back. More impressive numbers, but it removes the cost defence
     during the test, and the app's real limit is the throttle anyway.
3. **Model quality as part of observability.**
   - **A. Yes** (recommended): build the CI role for the weekly summary eval
     (`EVAL_ROLE_ARN`, waiting since mcp-servers#15). The eval's pass rate
     becomes a quality signal over time, next to the latency and error SLIs.
   - B. Later: keep step 10 to the roadmap's list.

## 8. Cost

Expected: **€0 a month extra**, if we stay inside the free tiers (10 alarm
metrics, 3 dashboards, log metric filters on existing logs, SNS email,
2 budgets). The load test itself costs fractions of a cent (a few thousand
API calls, no Bedrock volume). The weekly eval, if chosen: about $0.30 a run
for the cheaper models, $3 with Claude and Nova, so the weekly run would use
the production model plus one or two others.

Fixed costs to flag before creating them: none planned. A fourth dashboard
($3/month) or more than ten alarms ($0.10 each) would be the first.
