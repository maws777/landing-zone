# 03-dns

The DNS zone for the app (roadmap step 7): a Route 53 public hosted zone for
`lab.michaelteplov.com` in the `network` account, delegated from GoDaddy.
Step 8 puts the MCP endpoint, the dashboard and the ACM validation records in
it. Decisions and trade-offs are in
[ADR 0011](../../docs/decisions/0011-dns-delegated-subdomain.md).

## What it creates

| Resource | Account | Notes |
|---|---|---|
| Hosted zone `lab.michaelteplov.com` | network | Public, `prevent_destroy`, the CI apply role can't delete it |

Cost: **$0.50/month** for the zone, plus $0.40 per million queries
(negligible). The project's first fixed cost beyond the free foundation.

## How the delegation works

`michaelteplov.com` stays at GoDaddy. Route 53 only answers for the
`lab.` subtree, because GoDaddy's zone says so with four NS records:

```
lab   NS   ns-123.awsdns-45.com.     <- the four values from `terraform output name_servers`
lab   NS   ns-678.awsdns-90.net.
lab   NS   ns-1234.awsdns-56.org.
lab   NS   ns-1890.awsdns-12.co.uk.
```

A resolver looking up `mcp.lab.michaelteplov.com` asks the `.com` servers,
which send it to GoDaddy, which sends it to these four AWS servers. Each zone
gets a random set of name servers when it's created, which is why the zone is
protected from deletion: a new zone would mean redoing the NS records.

Check the delegation (after adding the records at GoDaddy; it can take a
few minutes to an hour, depending on caching):

```powershell
nslookup -type=NS lab.michaelteplov.com 8.8.8.8
```

The answer should list the four `awsdns` servers.

## Two accounts, one stage

| Who runs it | Identity in network | Set by |
|---|---|---|
| CI, pull request | assumes `ci/landing-zone-ci-dns-plan` | workflow env (`network_role_name`) |
| CI, apply on `main` | assumes `ci/landing-zone-ci-dns-apply` | workflow env (`network_role_name`) |
| Locally | Identity Center profile `network-admin` | `terraform.tfvars` (`network_profile`) |

The default provider (management) is only used to look up the network
account's ID in the organization. The CI roles are created by `00-bootstrap`
(`network-access.tf`): Route 53 only, no `DeleteHostedZone`, each trusting
only the matching CI role in management.

## Running it locally

Normally CI applies this stage. For a local plan:

```powershell
aws sso login --profile management-admin
cd stages/03-dns
$env:AWS_PROFILE = "management-admin"
terraform init "-backend-config=backend.hcl"
terraform plan
```

`terraform.tfvars` (gitignored) holds `management_account_id` and
`network_profile = "network-admin"`; `backend.hcl` is the same as in the
other stages.
