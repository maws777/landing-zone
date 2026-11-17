"""lz-remediate: classify a risky API call, revert it when that's safe, alert.

Input: a CloudTrail event ("AWS API Call via CloudTrail") forwarded from any
account of the organization to the lz-detection bus (ADR 0016).

    classify(event) -> Finding | None   pure, unit-tested (tests/)
    handler(event)  -> record once, revert, alert

Reverts (only these two, both harmless to re-apply):
  - S3 bucket made public       -> Block Public Access back on, all four flags
  - SSH/RDP open to the world   -> revoke exactly the rules that were added
Alert only:
  - broad IAM grants, guardrail changes (SCPs, CloudTrail). A wrong revert
    there can lock me out, or fight a legitimate break-glass (ADR 0010).

Never logs or sends policy documents or request bodies: only what changed,
where, and who did it.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field

WORLD = {"0.0.0.0/0", "::/0"}
ADMIN_PORTS = {22: "SSH", 3389: "RDP"}
ADMIN_POLICY_ARNS = {"arn:aws:iam::aws:policy/AdministratorAccess", "arn:aws:iam::aws:policy/IAMFullAccess"}
REMEDIATION_ROLE = os.environ.get("REMEDIATION_ROLE", "lz/lz-remediation")


@dataclass
class Finding:
    kind: str  # s3-public, sg-open-admin-port, iam-broad-grant, guardrail-change
    summary: str  # one line, for the alert subject and the table
    action: str  # "revert" or "alert"
    revert: dict = field(default_factory=dict)  # what the revert needs


# --- Classification (pure) ----------------------------------------------------


def classify(event: dict) -> Finding | None:
    d = event.get("detail", {})
    if d.get("errorCode"):
        return None  # the call failed: nothing changed
    if _is_own_action(d):
        return None  # our own revert, seen again: no loop

    name = d.get("eventName", "")
    params = d.get("requestParameters") or {}
    source = event.get("source", "")

    if source == "aws.s3":
        return _s3(name, params)
    if source == "aws.ec2":
        return _ec2(name, params, d.get("responseElements") or {})
    if source == "aws.iam":
        return _iam(name, params, d)
    if source in ("aws.organizations", "aws.cloudtrail"):
        return Finding("guardrail-change", f"{name} by {_who(d)}", "alert")
    return None


def _is_own_action(d: dict) -> bool:
    arn = (d.get("userIdentity") or {}).get("arn", "")
    issuer = ((d.get("userIdentity") or {}).get("sessionContext") or {}).get("sessionIssuer", {}).get("arn", "")
    return REMEDIATION_ROLE in arn or REMEDIATION_ROLE in issuer


def _s3(name: str, p: dict) -> Finding | None:
    bucket = p.get("bucketName")
    if not bucket:
        return None
    revert = {"bucket": bucket}
    if name == "DeletePublicAccessBlock":
        return Finding("s3-public", f"Block Public Access removed on {bucket}", "revert", revert)
    if name == "PutBucketPublicAccessBlock":
        conf = p.get("PublicAccessBlockConfiguration") or {}
        flags = ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")
        if any(conf.get(f) is False for f in flags):
            return Finding("s3-public", f"Block Public Access weakened on {bucket}", "revert", revert)
        return None
    if name == "PutBucketPolicy":
        if _policy_allows_anyone(p.get("bucketPolicy")):
            return Finding("s3-public", f"Public bucket policy on {bucket}", "revert", revert)
        return None
    if name == "PutBucketAcl":
        if "AllUsers" in json.dumps(p) or "AuthenticatedUsers" in json.dumps(p) or p.get("x-amz-acl") in (
            "public-read",
            "public-read-write",
            "authenticated-read",
        ):
            return Finding("s3-public", f"Public ACL on {bucket}", "revert", revert)
    return None


def _policy_allows_anyone(policy) -> bool:
    if isinstance(policy, str):
        try:
            policy = json.loads(policy)
        except ValueError:
            return False
    statements = (policy or {}).get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    for s in statements:
        if s.get("Effect") != "Allow" or s.get("Condition"):
            continue  # a condition (source VPC, org ID...) usually scopes it: not "anyone"
        principal = s.get("Principal")
        if principal == "*" or (isinstance(principal, dict) and "*" in _as_list(principal.get("AWS"))):
            return True
    return False


def _ec2(name: str, p: dict, resp: dict) -> Finding | None:
    if name != "AuthorizeSecurityGroupIngress":
        return None  # ModifySecurityGroupRules: alert-worthy too, but v1 reverts additions only
    group = p.get("groupId")
    opened = []
    for perm in _items(p.get("ipPermissions")):
        ranges = [r.get("cidrIp") for r in _items(perm.get("ipRanges"))] + [
            r.get("cidrIpv6") for r in _items(perm.get("ipv6Ranges"))
        ]
        if not WORLD.intersection(ranges):
            continue
        proto = str(perm.get("ipProtocol"))
        lo, hi = perm.get("fromPort"), perm.get("toPort")
        for port, label in ADMIN_PORTS.items():
            if proto == "-1" or (proto in ("tcp", "6") and lo is not None and hi is not None and lo <= port <= hi):
                opened.append(label)
    if not group or not opened:
        return None
    rule_ids = [r.get("securityGroupRuleId") for r in _items(resp.get("securityGroupRuleSet")) if r.get("securityGroupRuleId")]
    ports = "/".join(sorted(set(opened)))
    return Finding("sg-open-admin-port", f"{ports} open to the world on {group}", "revert", {"group": group, "rule_ids": rule_ids})


def _iam(name: str, p: dict, d: dict) -> Finding | None:
    target = p.get("roleName") or p.get("userName") or p.get("policyArn") or "?"
    if name in ("AttachRolePolicy", "AttachUserPolicy"):
        if p.get("policyArn") in ADMIN_POLICY_ARNS:
            return Finding("iam-broad-grant", f"{p['policyArn'].split('/')[-1]} attached to {target}", "alert")
        return None
    if name in ("PutRolePolicy", "PutUserPolicy", "CreatePolicyVersion"):
        if _policy_is_star_star(p.get("policyDocument")):
            return Finding("iam-broad-grant", f"Action * on Resource * granted ({name}, {target})", "alert")
        return None
    if name == "CreateRole":
        # The region SCP trusts this name pattern in us-east-1 (ADR 0016);
        # only CloudFormation StackSets should ever create it.
        role = p.get("roleName", "")
        if role.startswith("stacksets-exec-") and "cloudformation" not in (d.get("userIdentity") or {}).get("invokedBy", ""):
            return Finding("iam-broad-grant", f"Role {role} created by {_who(d)} (name trusted by the region SCP)", "alert")
    return None


def _policy_is_star_star(policy) -> bool:
    if isinstance(policy, str):
        try:
            policy = json.loads(policy)
        except ValueError:
            return False
    statements = (policy or {}).get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    return any(
        s.get("Effect") == "Allow" and "*" in _as_list(s.get("Action")) and "*" in _as_list(s.get("Resource"))
        for s in statements
    )


def _who(d: dict) -> str:
    ui = d.get("userIdentity") or {}
    issuer = (ui.get("sessionContext") or {}).get("sessionIssuer", {}).get("arn")
    return issuer or ui.get("arn") or ui.get("type", "?")


def _items(x) -> list:
    if isinstance(x, dict):
        return x.get("items") or []
    return x or []


def _as_list(x) -> list:
    return x if isinstance(x, list) else [x]


# --- Side effects ---------------------------------------------------------------


def handler(event, _context=None):
    import boto3  # in the Lambda runtime; imported here so tests need no AWS SDK

    finding = classify(event)
    d = event.get("detail", {})
    if finding is None:
        print(json.dumps({"event": "ignored", "name": d.get("eventName")}))
        return

    account = event.get("account") or d.get("recipientAccountId")
    region = d.get("awsRegion") or event.get("region")
    event_id = d.get("eventID") or event.get("id")

    ddb = boto3.client("dynamodb")
    try:
        ddb.put_item(
            TableName=os.environ["FINDINGS_TABLE"],
            Item={
                "PK": {"S": f"FINDING#{event.get('time', '')[:10]}"},
                "SK": {"S": f"{event.get('time', '')}#{event_id}"},
                "kind": {"S": finding.kind},
                "summary": {"S": finding.summary},
                "account": {"S": str(account)},
                "region": {"S": str(region)},
                "who": {"S": _who(d)},
                "action": {"S": finding.action},
                "outcome": {"S": "pending"},
                "expires_at": {"N": str(int(time.time()) + 90 * 24 * 3600)},
            },
            ConditionExpression="attribute_not_exists(PK)",
        )
    except ddb.exceptions.ConditionalCheckFailedException:
        print(json.dumps({"event": "duplicate", "kind": finding.kind}))
        return  # already handled: EventBridge delivered it twice

    outcome = "alerted"
    if finding.action == "revert":
        try:
            _revert(boto3, finding, account, region)
            outcome = "reverted"
        except Exception as e:  # report, don't retry forever
            outcome = f"revert failed: {type(e).__name__}"

    ddb.update_item(
        TableName=os.environ["FINDINGS_TABLE"],
        Key={"PK": {"S": f"FINDING#{event.get('time', '')[:10]}"}, "SK": {"S": f"{event.get('time', '')}#{event_id}"}},
        UpdateExpression="SET outcome = :o",
        ExpressionAttributeValues={":o": {"S": outcome}},
    )

    subject = f"[landing-zone] {finding.kind}: {outcome}"
    body = "\n".join(
        [
            finding.summary,
            f"Account: {account}  Region: {region}",
            f"By: {_who(d)}",
            f"Call: {d.get('eventSource')} {d.get('eventName')} at {d.get('eventTime')}",
            f"Outcome: {outcome}",
            f"CloudTrail event ID: {event_id}",
        ]
    )
    boto3.client("sns").publish(TopicArn=os.environ["ALERT_TOPIC_ARN"], Subject=subject[:100], Message=body)
    print(json.dumps({"event": "finding", "kind": finding.kind, "outcome": outcome, "account": account}))


def _revert(boto3, finding: Finding, account: str, region: str) -> None:
    creds = boto3.client("sts").assume_role(
        RoleArn=f"arn:aws:iam::{account}:role/{REMEDIATION_ROLE}",
        RoleSessionName="lz-remediate",
        DurationSeconds=900,
    )["Credentials"]
    session = boto3.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        region_name=region,
    )
    if finding.kind == "s3-public":
        session.client("s3").put_public_access_block(
            Bucket=finding.revert["bucket"],
            PublicAccessBlockConfiguration={
                "BlockPublicAcls": True,
                "IgnorePublicAcls": True,
                "BlockPublicPolicy": True,
                "RestrictPublicBuckets": True,
            },
        )
    elif finding.kind == "sg-open-admin-port":
        if finding.revert["rule_ids"]:
            session.client("ec2").revoke_security_group_ingress(
                GroupId=finding.revert["group"], SecurityGroupRuleIds=finding.revert["rule_ids"]
            )
        else:
            raise RuntimeError("no rule IDs in the event")
