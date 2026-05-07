output "instance_id" {
  value = aws_instance.keeper.id
}

output "private_ip" {
  value = aws_instance.keeper.private_ip
}

output "name" {
  value = var.name
}

output "server_id" {
  value = var.server_id
}
