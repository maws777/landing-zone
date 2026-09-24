# Day 0: manual foundation

Everything in this project is Terraform except the steps on this page. These came
first, by hand in the console, because they are the things Terraform cannot
bootstrap itself into: an AWS account has to exist before anything can manage it,
and an organization has to exist before an organization API call can be made.

This is written as a runbook. Someone starting from nothing should be able to
follow it in order and end up where this repo begins.

Region for everything: **Europe (Paris), `eu-west-3`**. One region keeps the
future "deny every region but this one" SCP simple, and keeps data in the EU.

---

## 1. A fresh management account

**What:** Created a new AWS account to be the organization's management account.
Root email is a Gmail `+` alias (`<user>+aws-management@gmail.com` style), so
every future account gets its own unique address out of one real mailbox.

**Where:** aws.amazon.com → Create an AWS Account.

**Why fresh:** an old personal account carried leftover resources and unclear
history. The management account sits at the top of the organization and cannot
be constrained by Service Control Policies — SCPs do not apply to it. So it is
the one account where a mistake is least contained, which is exactly why it
should hold as little as possible: no workloads, no experiments. It runs
Organizations, Identity Center, and billing, and nothing else.

**Why the `+` alias:** AWS requires a unique root email per account. Gmail
delivers `user+anything@gmail.com` to `user@gmail.com`, so one inbox covers all
seven accounts with no extra mailboxes to own or forward.

## 2. Lock down the root user

**What:** Enabled MFA on the root user. Confirmed root has no access keys.

**Where:** Console as root → IAM → Security credentials.

**Why:** root can do anything in the account and cannot be restricted by any
policy — no SCP, no IAM boundary, nothing. It is the one identity where the only
available control is making it hard to use and rarely used. After this step root
is reserved for the handful of tasks that genuinely require it (closing the
account, changing the support plan, a few billing settings) and every day-to-day
action happens through Identity Center instead.

Access keys on root would be worse than a password: a long-lived unrestricted
credential sitting in a file somewhere. There are none, and there never will be.

## 3. Billing access and a budget

**What:** Activated "IAM access to billing information" in account settings, then
created a budget in AWS Budgets with email alerts.

**Where:** Account settings → IAM user and role access to billing information.
Then Billing → Budgets → Create budget.

**Why billing access first:** without that setting, billing pages are visible
*only* to root, no matter what IAM or Identity Center permissions say. An admin
who cannot see the bill cannot notice a problem.

**Why budgets before infrastructure:** this project has a real budget of about
€10–15/month and no new-customer credits, so every mistake costs actual money.
A forgotten NAT Gateway is roughly €30/month on its own. The alert is the
difference between finding out in two days and finding out on the invoice.

The budget is manual for now and moves into Terraform later. Being warned
immediately mattered more than being warned reproducibly.

## 4. AWS Organizations

**What:** Enabled AWS Organizations with **all features**. Created nothing
inside it — no OUs, no member accounts, no policies.

**Where:** Console → AWS Organizations → Create an organization.

**Why all features:** "consolidated billing only" mode gives shared billing and
nothing else. All features is what unlocks Service Control Policies and trusted
access for other services, which is the entire point here. Switching modes later
requires every member account to approve, so it is worth getting right once.

Everything else — the OUs, the six member accounts, the SCPs — is Terraform's
job in `stages/00-bootstrap`. The organization itself is brought under Terraform
with an `import` block rather than recreated.

Note: root email verification for Organizations may still be pending at this
point. Account creation will fail until it completes.

## 5. IAM Identity Center

**What:** Enabled IAM Identity Center as an **organization instance**,
**Single-Region** in `eu-west-3`.

**Where:** Console → IAM Identity Center → Enable.

**The Single-Region choice.** The console offered a Multi-Region instance
replicated to Oregon (`us-west-2`). Single-Region was chosen for two reasons:
identity data stays in the EU, and the future region-restriction SCP stays
simple — a policy that denies everything outside `eu-west-3` does not need
carve-outs for an identity service quietly replicating to Oregon.

The cost is availability: if `eu-west-3` has an outage, the sign-in portal is
unreachable, and recovery means the root user. Acceptable for a lab. Replicating
to a second EU region such as Ireland is a reasonable later addition, and would
be documented as one. See `decisions/0003-identity-center-single-region.md`.

**Configuration:**

- Identity source: the default Identity Center directory. No external IdP —
  there is no existing corporate directory to federate with, and the built-in
  one costs nothing.
- MFA required at every sign-in.
- Group `admins`; user `michael`, member of `admins`.
- Permission set `AdministratorAccess` (the AWS managed policy), assigned to
  group `admins` on the management account.

**The access model.** Usernames identify *people*. Permissions come from
*groups* and *permission sets*, never from a user directly. So access changes
are group membership changes, and "what can this person do" is answerable by
looking at which groups they are in rather than auditing per-user grants.

**What a permission set actually is.** A permission set is a template, not a
permission. When a permission set is assigned to a group on an account,
Identity Center creates a real IAM role in *that* account named
`AWSReservedSSO_<permission-set>_<random suffix>`, with the permission set's
policies attached and a trust policy that lets Identity Center assume it. That
is the whole mechanism: signing in through the portal is Identity Center
assuming that role on your behalf and handing back temporary credentials.

Two consequences worth remembering. Editing a permission set rewrites those
roles in every account it is assigned to. And because the suffix is generated,
the role name is not predictable — anything that needs to reference it should
match on a prefix rather than a literal name.

## 6. AWS CLI with SSO

**What:** Configured AWS CLI v2 to authenticate through Identity Center. No
long-lived access keys on this machine.

```
aws configure sso
```

Answers used:

| Prompt | Value |
|---|---|
| SSO session name | `mteplov` |
| SSO start URL | `https://<subdomain>.awsapps.com/start` |
| SSO region | `eu-west-3` |
| SSO registration scopes | `sso:account:access` |
| Profile name | `management-admin` |
| Default region | `eu-west-3` |

Verified with:

```
aws sts get-caller-identity --profile management-admin
```

which returns an ARN of the form
`arn:aws:sts::<account-id>:assumed-role/AWSReservedSSO_AdministratorAccess_<suffix>/michael`
— the role from step 5, confirming the whole chain works.

**How this works.** `aws sso login` starts an OAuth 2.0 authorization code flow
with PKCE. The CLI registers itself as a client, opens a browser to the portal,
and waits. You authenticate there (with MFA) and approve the request; the
browser is redirected back to a local port with a short-lived authorization
code. The CLI exchanges that code — along with a verifier proving it is the same
client that started the flow, which is what PKCE adds — for an access token, and
caches the token under `~/.aws/sso/cache/`.

From then on, each command trades that token for temporary credentials for the
specific role, valid for a matter of hours. Nothing durable is stored. When the
token expires, commands start failing with an expired-token error and the fix is:

```
aws sso login --profile management-admin
```

**Why this matters.** The alternative is an IAM user with an access key pair in
`~/.aws/credentials`: a permanent secret in a plaintext file, which is the most
common way AWS credentials leak. Here the worst case is a token that dies on its
own within hours, and revoking access means removing a group membership rather
than hunting down every copy of a key.

A profile per account (`log-archive-admin`, `network-admin`, `prod-admin`, …)
gets added once the member accounts exist.

## 7. Domain

**What:** `michaelteplov.com`, registered at GoDaddy under my own name (moved
from a family member's account).

**Why:** DNS only. Later, a subdomain (`lab.michaelteplov.com`) is delegated to
a Route 53 hosted zone by adding NS records at GoDaddy, which is what the ALB
certificate and the MCP server endpoint will live under. Delegating a subdomain
rather than moving the whole domain to Route 53 means the apex is untouched and
the lab cannot break anything else.

AWS Organizations does not need a domain at all. This is groundwork for the app.

---

## Things that went wrong

**The wrong username, remembered.** The Identity Center sign-in page had
`mte-management` saved in the username field — a name that is not an Identity
Center user at all. Logins failed, and the password reset returned "Access
denied", which reads like a permissions problem and is not one. The actual user
is `michael`. The reset was failing because the account being reset did not
exist.

The lesson is worth stating plainly, because it cost real time: **AWS has three
different sign-in pages, for three different kinds of identity.**

| Page | Identity | Used for |
|---|---|---|
| `signin.aws.amazon.com/console` (root) | root email + password | rare root-only tasks |
| Same page, "IAM user" | account ID + IAM username | not used in this project |
| `https://<subdomain>.awsapps.com/start` | Identity Center username | all normal access |

They look similar, they share nothing, and a username from one is meaningless on
another. A saved-credential autofill from the wrong one produces failures that
look like permission errors instead of "no such user". When a sign-in fails, the
first question is which page you are on.

---

## Where this leaves things

In place: a locked-down management account, a budget with alerts, an empty
organization with all features on, Identity Center with one admin who signs in
with MFA, and a CLI that holds no permanent credentials.

Next: `stages/00-bootstrap` imports the organization into Terraform and creates
the OUs, the member accounts, the Identity Center assignments, and the S3 state
bucket. See that stage's README.

Decisions recorded in `decisions/`:

- `0001-aws-as-cloud-provider.md`
- `0002-no-control-tower.md`
- `0003-identity-center-single-region.md`
