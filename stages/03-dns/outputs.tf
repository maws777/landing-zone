output "zone_id" {
  description = "Hosted zone ID. Step 8 adds the app's records and ACM validation records to it."
  value       = aws_route53_zone.lab.zone_id
}

output "name_servers" {
  description = "The four name servers to enter at GoDaddy as NS records for \"lab\" under michaelteplov.com."
  value       = aws_route53_zone.lab.name_servers
}
