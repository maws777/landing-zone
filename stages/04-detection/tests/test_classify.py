"""Unit tests for the classification half of lz-remediate (no AWS needed).

    python -m unittest discover -s stages/04-detection/tests
"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))
from remediate import classify  # noqa: E402

ADMIN = {"type": "AssumedRole", "arn": "arn:aws:sts::111111111111:assumed-role/AWSReservedSSO_Admin/michael"}


def ev(source, name, params=None, resp=None, identity=ADMIN, error=None):
    detail = {
        "eventName": name,
        "eventSource": source.replace("aws.", "") + ".amazonaws.com",
        "requestParameters": params or {},
        "responseElements": resp,
        "userIdentity": identity,
        "eventID": "e1",
        "awsRegion": "eu-west-3",
    }
    if error:
        detail["errorCode"] = error
    return {"source": source, "account": "111111111111", "time": "2026-11-17T10:00:00Z", "detail": detail}


class S3(unittest.TestCase):
    def test_block_public_access_removed_is_reverted(self):
        f = classify(ev("aws.s3", "DeletePublicAccessBlock", {"bucketName": "b"}))
        self.assertEqual((f.kind, f.action, f.revert), ("s3-public", "revert", {"bucket": "b"}))

    def test_weakened_block_is_reverted_full_block_is_not(self):
        weak = {"bucketName": "b", "PublicAccessBlockConfiguration": {"BlockPublicAcls": True, "IgnorePublicAcls": True, "BlockPublicPolicy": False, "RestrictPublicBuckets": True}}
        full = {"bucketName": "b", "PublicAccessBlockConfiguration": dict.fromkeys(["BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets"], True)}
        self.assertEqual(classify(ev("aws.s3", "PutBucketPublicAccessBlock", weak)).action, "revert")
        self.assertIsNone(classify(ev("aws.s3", "PutBucketPublicAccessBlock", full)))

    def test_public_policy_vs_scoped_policy(self):
        public = {"Statement": [{"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "*"}]}
        scoped = {"Statement": [{"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "*", "Condition": {"StringEquals": {"aws:PrincipalOrgID": "o-x"}}}]}
        cloudfront = {"Statement": [{"Effect": "Allow", "Principal": {"Service": "cloudfront.amazonaws.com"}, "Action": "s3:GetObject", "Resource": "*"}]}
        self.assertEqual(classify(ev("aws.s3", "PutBucketPolicy", {"bucketName": "b", "bucketPolicy": json.dumps(public)})).kind, "s3-public")
        self.assertIsNone(classify(ev("aws.s3", "PutBucketPolicy", {"bucketName": "b", "bucketPolicy": scoped})))
        self.assertIsNone(classify(ev("aws.s3", "PutBucketPolicy", {"bucketName": "b", "bucketPolicy": cloudfront})))

    def test_public_acl(self):
        self.assertEqual(classify(ev("aws.s3", "PutBucketAcl", {"bucketName": "b", "x-amz-acl": "public-read"})).kind, "s3-public")
        self.assertIsNone(classify(ev("aws.s3", "PutBucketAcl", {"bucketName": "b", "x-amz-acl": "private"})))


class SecurityGroups(unittest.TestCase):
    def sg(self, proto, lo, hi, cidr="0.0.0.0/0", v6=False):
        rng = {"ipv6Ranges": {"items": [{"cidrIpv6": cidr}]}} if v6 else {"ipRanges": {"items": [{"cidrIp": cidr}]}}
        params = {"groupId": "sg-1", "ipPermissions": {"items": [{"ipProtocol": proto, "fromPort": lo, "toPort": hi, **rng}]}}
        resp = {"securityGroupRuleSet": {"items": [{"securityGroupRuleId": "sgr-1"}]}}
        return classify(ev("aws.ec2", "AuthorizeSecurityGroupIngress", params, resp))

    def test_ssh_and_rdp_open_to_the_world_are_reverted(self):
        f = self.sg("tcp", 22, 22)
        self.assertEqual((f.kind, f.revert), ("sg-open-admin-port", {"group": "sg-1", "rule_ids": ["sgr-1"]}))
        self.assertIn("RDP", self.sg("tcp", 3389, 3389).summary)
        self.assertIn("SSH", self.sg("tcp", 0, 65535, "::/0", v6=True).summary)
        self.assertIn("SSH", self.sg("-1", None, None).summary)

    def test_https_or_private_range_is_fine(self):
        self.assertIsNone(self.sg("tcp", 443, 443))
        self.assertIsNone(self.sg("tcp", 22, 22, "10.0.0.0/8"))


class Iam(unittest.TestCase):
    def test_admin_policy_attached_alerts_only(self):
        f = classify(ev("aws.iam", "AttachRolePolicy", {"roleName": "r", "policyArn": "arn:aws:iam::aws:policy/AdministratorAccess"}))
        self.assertEqual((f.kind, f.action), ("iam-broad-grant", "alert"))
        self.assertIsNone(classify(ev("aws.iam", "AttachRolePolicy", {"roleName": "r", "policyArn": "arn:aws:iam::aws:policy/ReadOnlyAccess"})))

    def test_star_star_inline_policy(self):
        doc = json.dumps({"Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]})
        narrow = json.dumps({"Statement": [{"Effect": "Allow", "Action": "s3:*", "Resource": "*"}]})
        self.assertEqual(classify(ev("aws.iam", "PutRolePolicy", {"roleName": "r", "policyDocument": doc})).action, "alert")
        self.assertIsNone(classify(ev("aws.iam", "PutRolePolicy", {"roleName": "r", "policyDocument": narrow})))

    def test_role_named_like_stacksets_exec(self):
        by_human = classify(ev("aws.iam", "CreateRole", {"roleName": "stacksets-exec-123"}))
        by_cfn = classify(ev("aws.iam", "CreateRole", {"roleName": "stacksets-exec-123"}, identity={**ADMIN, "invokedBy": "cloudformation.amazonaws.com"}))
        self.assertEqual(by_human.action, "alert")
        self.assertIsNone(by_cfn)


class Guards(unittest.TestCase):
    def test_guardrail_changes_alert(self):
        self.assertEqual(classify(ev("aws.organizations", "DetachPolicy", {"policyId": "p"})).kind, "guardrail-change")
        self.assertEqual(classify(ev("aws.cloudtrail", "StopLogging", {"name": "t"})).action, "alert")

    def test_failed_calls_and_own_reverts_are_ignored(self):
        self.assertIsNone(classify(ev("aws.s3", "DeletePublicAccessBlock", {"bucketName": "b"}, error="AccessDenied")))
        own = {"type": "AssumedRole", "arn": "arn:aws:sts::111111111111:assumed-role/lz-remediation/lz-remediate", "sessionContext": {"sessionIssuer": {"arn": "arn:aws:iam::111111111111:role/lz/lz-remediation"}}}
        self.assertIsNone(classify(ev("aws.s3", "DeletePublicAccessBlock", {"bucketName": "b"}, identity=own)))


if __name__ == "__main__":
    unittest.main()
