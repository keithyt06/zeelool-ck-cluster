output "dns_name" {
  value       = aws_lb.this.dns_name
  description = "AWS-owned NLB DNS name (e.g. xxx.elb.<region>.amazonaws.com). Clients connect to this directly — there is no Route53 alias in this project."
}

output "zone_id" {
  value       = aws_lb.this.zone_id
  description = "NLB canonical hosted zone id — pass to aws_route53_record.alias.zone_id in the caller's own DNS if they want to build a CNAME/alias in their own zone."
}

output "nlb_arn" {
  value = aws_lb.this.arn
}
