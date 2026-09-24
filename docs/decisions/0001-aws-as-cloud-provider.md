# 1. AWS as the cloud provider

Date: 2026-09-24

Status: accepted

## Context

This project is a portfolio piece: it exists to show that I can design and run a
secure multi-account cloud platform. The provider choice is therefore partly a
technical decision and partly a career one.

I already have production experience with GCP and Azure from my internship. That
covers two of the three major providers, and a second project on either of them
would mostly repeat what I can already evidence.

AWS has the largest market share of the three, so it appears in the most job
descriptions. It is also the provider whose multi-account model is the most
developed and the most opinionated — Organizations, OUs, Service Control
Policies, IAM Identity Center — which gives a landing-zone project more to
actually build and more to explain.

## Decision

Build on AWS.

## Consequences

Good:

- Completes coverage of all three major providers across my projects and
  experience, which is a stronger claim than depth in one.
- The account-boundary-as-security-boundary model, SCPs, and Identity Center are
  substantial enough to carry a whole project, and the concepts transfer: AWS
  Organizations to GCP folders, SCPs to Azure Policy.
- Largest hiring surface of the three.
- The best-documented provider, and the one with the most third-party material
  when something goes wrong.

Costs and risks:

- No new-customer credits are available to me — the old personal account used
  them up — so this runs on real money against a €10–15/month budget. Cost
  awareness is a constraint on every later decision rather than an afterthought,
  which is why the expensive app runtime is deployed only when in use and
  destroyed afterwards.
- AWS IAM is the most intricate of the three permission models. That is a
  learning cost, and it is also part of the point.
- Vendor-specific work: Organizations and SCPs do not translate directly to
  another provider, so some of this is not portable knowledge.
