output "dns_name" {
  value = aws_lb.this.dns_name
}

output "alias_fqdn" {
  value = aws_route53_record.alias.fqdn
}

output "nlb_arn" {
  value = aws_lb.this.arn
}
