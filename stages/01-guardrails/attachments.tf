# Where each SCP is attached. The one file to change when widening a rollout.
#
# Rollout, one pull request per step:
#   1. Sandbox OU only (done, PR #4). Nothing lives there yet, so a policy that
#      is wrong breaks nothing that matters, and it can be tested for real from
#      the sandbox-admin profile.
#   2. The organization root (current). Everything under the root inherits it: every OU,
#      every account, including accounts and OUs created later, so nothing can
#      escape a guardrail by being put somewhere new. (The management account
#      stays exempt; SCPs never apply to it.)
#
# Limit to keep in mind: at most 5 SCPs per target, and FullAWSAccess already
# uses one of them at the root.

locals {
  scp_targets = {
    root = local.root_id
  }

  policies = {
    baseline = aws_organizations_policy.baseline.id
    region   = aws_organizations_policy.region.id
  }

  # Every policy on every target: "baseline/sandbox" => { policy_id, target_id }
  attachments = {
    for pair in setproduct(keys(local.policies), keys(local.scp_targets)) :
    "${pair[0]}/${pair[1]}" => {
      policy_id = local.policies[pair[0]]
      target_id = local.scp_targets[pair[1]]
    }
  }
}

resource "aws_organizations_policy_attachment" "this" {
  for_each = local.attachments

  policy_id = each.value.policy_id
  target_id = each.value.target_id
}
