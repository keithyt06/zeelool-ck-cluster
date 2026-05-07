output "instance_profile_name" {
  value       = aws_iam_instance_profile.ck_node.name
  description = "Instance profile for ClickHouse data nodes (with S3 backup permissions)"
}

output "instance_profile_arn" {
  value = aws_iam_instance_profile.ck_node.arn
}

output "role_name" {
  value = aws_iam_role.ck_node.name
}

output "role_arn" {
  value = aws_iam_role.ck_node.arn
}

output "keeper_instance_profile_name" {
  value       = aws_iam_instance_profile.keeper.name
  description = "Instance profile for Keeper nodes (SSM only, no S3 write)"
}

output "keeper_role_arn" {
  value = aws_iam_role.keeper.arn
}
