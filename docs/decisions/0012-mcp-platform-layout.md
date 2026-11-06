# 12. MCP platform: one server per app, one repo, shared identity

Date: 2026-11-06

Status: accepted (nothing built yet; roadmap step 8)

## Context

The calorie tracker is the first of several personal apps I want to use from
Claude. Each one is an MCP server: tools Claude calls with structured values,
behind OAuth. Two shapes are possible:

- **One global MCP server** that exposes every app's tools, or a gateway that
  proxies to per-app backends.
- **One MCP server per app**, each its own connector in Claude.

And a few things the landing zone has to settle before the first app exists:
where the code lives, how its resources are named, where its users sign in,
and which language it is written in.

## Decision

**One MCP server per app, all in one repository (`mcp-servers`), sharing one
Cognito user pool per environment.**

- **Per app:** its own Lambda, its own DynamoDB table, its own ECR repository,
  its own endpoint (`<app>.mcp.staging.lab.michaelteplov.com` in staging,
  `<app>.mcp.lab.michaelteplov.com` in prod) and its own OAuth scopes
  (`food:read`, `food:write`, ...). Claude clients handle several connectors
  natively, and each conversation can enable only the ones it needs.
- **Shared per environment:** one Cognito user pool, so I sign in once. Each
  app is a resource server in that pool with its own scopes, and each app's
  OAuth client may only request that app's scopes. A token for the food server
  can't call another app's tools.
- **One repository**, so apps share code (token validation, logging, the
  Lambda container setup) and CI. Each app still deploys as its own stack.
- **Naming:** every AWS resource the repository creates starts with `mcp-`
  (functions, tables, log groups) or lives under `mcp/` (ECR repositories, IAM
  roles and policies). The CI permissions in ADR 0013 are scoped to those
  names.
- **TypeScript** with the official MCP SDK; schemas (Zod) do the "validate,
  sane ranges" part.
- **Staging first.** Prod gets the same setup once the first app works in
  staging.

Rejected: a single global server. Every tool of every app would sit in every
conversation (more tokens, worse tool choice), one token would carry every
app's scopes, a bug in one app could reach another app's data, and one
deployment would carry all of them. A gateway in front of per-app backends
fixes the coupling but adds a hop and a component, and is only worth it if
tools ever need to work across apps.

## Consequences

Good:

- Least privilege falls out of the layout: one IAM role, one table and one
  scope set per app. Diet data (possibly GDPR Article 9 health data) never
  shares a table or a role with anything else.
- Adding an app is a folder in the repository, a resource server and a client
  in Cognito, and a DNS name. The landing zone doesn't change.

Costs and risks:

- One connector per app in each Claude client.
- The shared user pool is a shared dependency: breaking it breaks sign-in for
  every app in that environment.
- Cross-app features (a summary that reads two apps) would need either a
  gateway or app-to-app calls. Not planned.
