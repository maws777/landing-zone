# Public hosted zone for lab.michaelteplov.com (roadmap step 7).
#
# How the delegation works: michaelteplov.com stays at GoDaddy. In GoDaddy's
# DNS for michaelteplov.com, four NS records named "lab" point at the name
# servers AWS assigns this zone (output `name_servers`). A resolver asking for
# anything.lab.michaelteplov.com gets sent by GoDaddy to those servers, so
# Route 53 answers for the whole lab.* subtree and nothing else.
#
# Cost: $0.50/month per hosted zone, plus $0.40 per million queries. The first
# fixed cost in the project beyond the free foundation.
#
# Why prevent_destroy: a new zone gets a new, random set of name servers. Lose
# this one and the NS records at GoDaddy point at servers that no longer answer
# for us, and every lab.* name breaks until they're redone by hand. The CI apply
# role can't delete zones either (00-bootstrap/network-access.tf).

resource "aws_route53_zone" "lab" {
  provider = aws.network

  name    = var.zone_name
  comment = "Delegated from GoDaddy. Managed by 03-dns."

  # Refuse to delete a zone that still has records, instead of wiping them.
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}
