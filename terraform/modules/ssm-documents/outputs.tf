output "install_keeper_doc_name" {
  value = aws_ssm_document.install_keeper.name
}

output "render_keeper_config_doc_name" {
  value = aws_ssm_document.render_keeper_config.name
}

output "install_clickhouse_doc_name" {
  value = aws_ssm_document.install_clickhouse.name
}

output "render_clickhouse_config_doc_name" {
  value = aws_ssm_document.render_clickhouse_config.name
}

output "bootstrap_schema_doc_name" {
  value = aws_ssm_document.bootstrap_schema.name
}

output "run_backup_doc_name" {
  value = aws_ssm_document.run_backup.name
}

output "resize_data_volume_doc_name" {
  value = aws_ssm_document.resize_data_volume.name
}
