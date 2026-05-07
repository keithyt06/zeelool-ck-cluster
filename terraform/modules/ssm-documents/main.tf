# Keeper documents
resource "aws_ssm_document" "install_keeper" {
  name            = "${var.name_prefix}-install-keeper"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/install-keeper.yml")

  tags = { Name = "${var.name_prefix}-install-keeper" }
}

resource "aws_ssm_document" "render_keeper_config" {
  name            = "${var.name_prefix}-render-keeper-config"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/render-keeper-config.yml")

  tags = { Name = "${var.name_prefix}-render-keeper-config" }
}

resource "aws_ssm_document" "install_clickhouse" {
  name            = "${var.name_prefix}-install-clickhouse"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/install-clickhouse.yml")

  tags = { Name = "${var.name_prefix}-install-clickhouse" }
}

resource "aws_ssm_document" "render_clickhouse_config" {
  name            = "${var.name_prefix}-render-clickhouse-config"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/render-clickhouse-config.yml")

  tags = { Name = "${var.name_prefix}-render-clickhouse-config" }
}

resource "aws_ssm_document" "bootstrap_schema" {
  name            = "${var.name_prefix}-bootstrap-schema"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/bootstrap-schema.yml")

  tags = { Name = "${var.name_prefix}-bootstrap-schema" }
}

resource "aws_ssm_document" "run_backup" {
  name            = "${var.name_prefix}-run-backup"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/run-backup.yml")

  tags = { Name = "${var.name_prefix}-run-backup" }
}

resource "aws_ssm_document" "resize_data_volume" {
  name            = "${var.name_prefix}-resize-data-volume"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/resize-data-volume.yml")

  tags = { Name = "${var.name_prefix}-resize-data-volume" }
}
