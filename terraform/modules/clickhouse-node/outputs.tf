output "instance_id" {
  value = aws_instance.clickhouse.id
}

output "private_ip" {
  value = aws_instance.clickhouse.private_ip
}

output "name" {
  value = var.name
}

output "replica_name" {
  value = var.replica_name
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}
