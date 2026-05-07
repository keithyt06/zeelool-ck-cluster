# ============================================================================
# Top-level composition for a zeelool-ck-style ClickHouse cluster.
#
# Customer portability: every region/VPC/AZ/IP/name specific value is derived
# from either (a) inputs the customer fills in tfvars, or (b) AWS data sources.
# No hardcoded region, CIDR, AZ name, route-table tag filter, or IP.
# ============================================================================

# -------- Discovery: subnets, route tables, AMI --------

data "aws_subnet" "private" {
  for_each = var.private_subnet_ids
  id       = each.value
}

# Discover the route table associated with each CK subnet. Used for the S3
# gateway endpoint (needs route_table_ids). This replaces a brittle tag filter
# that was specific to Keith's VPC.
data "aws_route_table" "by_subnet" {
  for_each  = var.private_subnet_ids
  subnet_id = each.value
}

# Latest Amazon Linux 2023 ARM64 AMI — region-agnostic SSM public parameter.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# -------- Locals: derive route tables, AZ names, private IPs --------

locals {
  # Route table IDs deduped across subnets (if two subnets share a route table,
  # the S3 endpoint association only needs it once).
  private_route_table_ids = distinct([for rt in data.aws_route_table.by_subnet : rt.id])

  # Real AZ names (ap-northeast-1a etc.) discovered from each subnet, keyed
  # by the customer's logical AZ key (az1a / az1c / az1d).
  subnet_az = { for k, s in data.aws_subnet.private : k => s.availability_zone }

  # Per-node private IPs. Override map wins if non-empty; else auto-compute
  # via cidrhost(subnet_cidr, offset + same-subnet-index). The same-subnet-index
  # is 0 for the first (lexicographic-smallest) Keeper in a subnet, 1 for the
  # second, etc. — so placing 2 Keepers in the same subnet yields distinct IPs
  # (e.g. .100 and .101) without the operator having to pin explicit IPs.
  #
  # Works on any VPC CIDR (10.0 / 172.16 / 192.168).
  keeper_same_subnet_index = {
    for node_name, cfg in var.keeper_placement :
    node_name => length([
      for other_name, other_cfg in var.keeper_placement :
      other_name if other_cfg.subnet_key == cfg.subnet_key && other_name < node_name
    ])
  }
  clickhouse_same_subnet_index = {
    for node_name, cfg in var.clickhouse_placement :
    node_name => length([
      for other_name, other_cfg in var.clickhouse_placement :
      other_name if other_cfg.subnet_key == cfg.subnet_key && other_name < node_name
    ])
  }
  keeper_private_ips = {
    for node_name, cfg in var.keeper_placement :
    node_name => lookup(
      var.keeper_private_ips_override,
      node_name,
      cidrhost(
        data.aws_subnet.private[cfg.subnet_key].cidr_block,
        var.keeper_ip_host_offset + local.keeper_same_subnet_index[node_name]
      )
    )
  }
  clickhouse_private_ips = {
    for node_name, cfg in var.clickhouse_placement :
    node_name => lookup(
      var.clickhouse_private_ips_override,
      node_name,
      cidrhost(
        data.aws_subnet.private[cfg.subnet_key].cidr_block,
        var.clickhouse_ip_host_offset + local.clickhouse_same_subnet_index[node_name]
      )
    )
  }
}

# -------- Modules --------

module "network" {
  source = "../../modules/network"

  name_prefix             = var.name_prefix
  vpc_id                  = var.vpc_id
  private_route_table_ids = local.private_route_table_ids
}

module "iam" {
  source = "../../modules/iam"

  name_prefix       = var.name_prefix
  backup_bucket_arn = module.backup_s3.bucket_arn
}

module "ssm_documents" {
  source = "../../modules/ssm-documents"

  name_prefix = var.name_prefix
}

module "keeper" {
  source   = "../../modules/keeper-node"
  for_each = var.keeper_placement

  name                  = each.key
  server_id             = each.value.server_id
  instance_type         = var.keeper_instance_type
  ami_id                = data.aws_ssm_parameter.al2023_arm64.value
  subnet_id             = var.private_subnet_ids[each.value.subnet_key]
  private_ip            = local.keeper_private_ips[each.key]
  security_group_ids    = [module.network.keeper_sg_id]
  instance_profile_name = module.iam.keeper_instance_profile_name
  key_name              = var.ssh_key_name
}

module "clickhouse" {
  source   = "../../modules/clickhouse-node"
  for_each = var.clickhouse_placement

  name                        = each.key
  replica_name                = each.key
  instance_type               = var.clickhouse_instance_type
  availability_zone           = local.subnet_az[each.value.subnet_key]
  ami_id                      = data.aws_ssm_parameter.al2023_arm64.value
  subnet_id                   = var.private_subnet_ids[each.value.subnet_key]
  private_ip                  = local.clickhouse_private_ips[each.key]
  security_group_ids          = [module.network.clickhouse_sg_id]
  instance_profile_name       = module.iam.instance_profile_name
  data_volume_gb              = var.clickhouse_data_volume_gb
  data_volume_iops            = var.clickhouse_data_volume_iops
  data_volume_throughput_mbps = var.clickhouse_data_volume_throughput_mbps
  key_name                    = var.ssh_key_name
}

# -------- NLB + backup (depend on clickhouse) --------

locals {
  # NLB spans all subnets used by Keeper OR CK (union of their subnet_keys).
  # Ensures the NLB has an ENI in every AZ the targets could be in.
  nlb_subnet_keys = distinct(concat(
    [for cfg in var.keeper_placement : cfg.subnet_key],
    [for cfg in var.clickhouse_placement : cfg.subnet_key],
  ))

  # Pick the first CK replica (by sorted node name) as the scheduled backup executor.
  # Only one replica runs the cron backup to avoid two copies writing the same
  # s3://.../full/<date>/ path and trampling each other's .lock file.
  backup_executor_name = sort(keys(var.clickhouse_placement))[0]
}

module "nlb" {
  source = "../../modules/nlb"

  name_prefix         = var.name_prefix
  vpc_id              = var.vpc_id
  subnet_ids          = [for k in local.nlb_subnet_keys : var.private_subnet_ids[k]]
  security_group_ids  = [module.network.nlb_sg_id]
  target_instance_ids = { for k, m in module.clickhouse : k => m.instance_id }
}

module "backup_s3" {
  source = "../../modules/backup-s3"

  name_prefix            = var.name_prefix
  bucket_name            = var.backup_bucket_name
  run_backup_doc_name    = module.ssm_documents.run_backup_doc_name
  ck_primary_instance_id = module.clickhouse[local.backup_executor_name].instance_id
}
