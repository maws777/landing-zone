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
# log-archive-protection skips the Sandbox step: the bucket it protects isn't
# in Sandbox, so there is nothing to test there. It names one bucket ARN, so
# at the root it can't affect anything else.
#
# break-glass (step 6, ADR 0010) is at step 1, on the Sandbox OU. Once tested,
# its statement moves into baseline-protections and the policy goes away.
#
# Limit to keep in mind: at most 5 SCPs per target. At the root: FullAWSAccess
# + baseline, region, log_archive = 4 of 5. The Bedrock exception (step 8) goes
# inside region-restriction, not into a new policy.

locals {
  scp_targets = {
    root    = local.root_id
    sandbox = local.ou_ids["Sandbox"]
  }

  # Each policy and the targets it is attached to.
  policies = {
    baseline    = { id = aws_organizations_policy.baseline.id, targets = ["root"] }
    region      = { id = aws_organizations_policy.region.id, targets = ["root"] }
    log_archive = { id = aws_organizations_policy.log_archive.id, targets = ["root"] }
    break_glass = { id = aws_organizations_policy.break_glass.id, targets = ["sandbox"] }
  }

  # "baseline/root" => { policy_id, target_id }. Same keys as before per-policy
  # targets existed, so the existing attachments stay put in state.
  attachments = merge([
    for name, policy in local.policies : {
      for target in policy.targets : "${name}/${target}" => {
        policy_id = policy.id
        target_id = local.scp_targets[target]
      }
    }
  ]...)
}

resource "aws_organizations_policy_attachment" "this" {
  for_each = local.attachments

  policy_id = each.value.policy_id
  target_id = each.value.target_id
}
