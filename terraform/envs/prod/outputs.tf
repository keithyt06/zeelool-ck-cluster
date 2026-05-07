output "region" {
  value       = var.region
  description = "AWS region (for use by scripts)"
}

output "name_prefix" {
  value = var.name_prefix
}

output "cluster_name" {
  value = var.cluster_name
}

output "clickhouse_sg_id" {
  value = module.network.clickhouse_sg_id
}

output "keeper_sg_id" {
  value = module.network.keeper_sg_id
}

output "nlb_sg_id" {
  value = module.network.nlb_sg_id
}

output "s3_endpoint_id" {
  value = module.network.s3_endpoint_id
}

output "instance_profile_name" {
  value = module.iam.instance_profile_name
}

output "keeper_instance_ids" {
  value = { for k, m in module.keeper : k => m.instance_id }
}

output "keeper_private_ips" {
  value = { for k, m in module.keeper : k => m.private_ip }
}

output "clickhouse_instance_ids" {
  value = { for k, m in module.clickhouse : k => m.instance_id }
}

output "clickhouse_private_ips" {
  value = { for k, m in module.clickhouse : k => m.private_ip }
}

output "clickhouse_nlb_dns" {
  value       = module.nlb.dns_name
  description = "AWS-owned NLB DNS name. Point clients at this host + port 9000 (native) or 8123 (HTTP)."
}

output "nlb_dns_name" {
  value       = module.nlb.dns_name
  description = "Alias for clickhouse_nlb_dns. Kept for scripts that still reference this name."
}

output "nlb_zone_id" {
  value       = module.nlb.zone_id
  description = "Canonical hosted zone id of the NLB — pass to aws_route53_record.alias.zone_id if you want to wire a CNAME in your own DNS."
}

output "backup_bucket_name" {
  value = module.backup_s3.bucket_name
}

output "backup_bucket_arn" {
  value = module.backup_s3.bucket_arn
}

# -------- Scripts-friendly aggregate output --------
# The single blob scripts consume for "give me everything you need to render
# configs / run smoke tests without duplicating cluster topology anywhere else".
output "cluster_info" {
  description = "All cluster topology data scripts need in one place."
  value = {
    region       = var.region
    name_prefix  = var.name_prefix
    cluster_name = var.cluster_name
    nlb_dns      = module.nlb.dns_name
    ssm_docs = {
      install_keeper           = module.ssm_documents.install_keeper_doc_name
      install_clickhouse       = module.ssm_documents.install_clickhouse_doc_name
      render_clickhouse_config = module.ssm_documents.render_clickhouse_config_doc_name
      render_keeper_config     = module.ssm_documents.render_keeper_config_doc_name
      bootstrap_schema         = module.ssm_documents.bootstrap_schema_doc_name
      run_backup               = module.ssm_documents.run_backup_doc_name
      resize_data_volume       = module.ssm_documents.resize_data_volume_doc_name
    }
    vpc_id = var.vpc_id
    backup = module.backup_s3.bucket_name
    keepers = {
      for k, cfg in var.keeper_placement : k => {
        instance_id = module.keeper[k].instance_id
        private_ip  = module.keeper[k].private_ip
        server_id   = cfg.server_id
      }
    }
    clickhouses = {
      for k, m in module.clickhouse : k => {
        instance_id = m.instance_id
        private_ip  = m.private_ip
      }
    }
  }
}
