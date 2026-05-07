output "clickhouse_sg_id" {
  value = aws_security_group.clickhouse.id
}

output "keeper_sg_id" {
  value = aws_security_group.keeper.id
}

output "nlb_sg_id" {
  value = aws_security_group.nlb.id
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
