# -------- AWS provider settings --------

variable "region" {
  type        = string
  default     = "ap-northeast-1"
  description = "AWS region to deploy into."
}

variable "profile" {
  type        = string
  default     = ""
  description = "AWS profile name. Empty = use ambient config (AWS_PROFILE env, instance profile, SSO)."
}

# -------- Naming & ownership (customer-facing overrides) --------

variable "name_prefix" {
  type        = string
  default     = "zeelool-ck"
  description = "Prefix used for every named AWS resource (SG names, IAM role names, NLB name, SSM Document names, EventBridge rule names, and the default backup S3 bucket). IAM role and S3 bucket names are globally scoped — change this when deploying a second copy into the same AWS account to avoid collisions."
}

variable "cluster_name" {
  type        = string
  default     = "zeelool_ck"
  description = "ClickHouse internal cluster identifier — appears in remote_servers.xml and system.clusters queries. Keep ASCII [a-z0-9_], no hyphens (ClickHouse cluster names can't contain '-')."
}

variable "owner" {
  type        = string
  default     = "keith"
  description = "Propagated to the Owner tag on every AWS resource via default_tags."
}

variable "environment" {
  type        = string
  default     = "prod"
  description = "Propagated to the Environment tag via default_tags."
}

variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Additional default tags merged onto every resource."
}

# -------- Network --------

variable "vpc_id" {
  type        = string
  description = "Existing VPC to deploy into. Its CIDR is discovered automatically."
}

variable "private_subnet_ids" {
  type        = map(string)
  description = "Map of logical-AZ-key -> private subnet ID. Minimum 2 subnets for 2-AZ deployments. Keys must match whatever you reference in keeper_placement / clickhouse_placement below (defaults: az1a, az1c)."
}

# -------- Node placement (maps logical AZ keys to subnets + server_id) --------

variable "keeper_placement" {
  type = map(object({
    subnet_key = string
    server_id  = number
  }))
  default = {
    "keeper-01" = { subnet_key = "az1a", server_id = 1 }
    "keeper-02" = { subnet_key = "az1a", server_id = 2 }
    "keeper-03" = { subnet_key = "az1c", server_id = 3 }
  }
  description = <<-EOT
    Keeper nodes, keyed by hostname/logical-name. subnet_key references a key
    in private_subnet_ids. server_id is the Raft ID (unique 1..N).

    Default is 2-AZ (2+1 split): az1a holds 2 Keepers, az1c holds 1 — matches
    customers with only 2 private AZs available.

    Fault tolerance is ASYMMETRIC with 2-AZ:
      - Losing az1c (1 Keeper)  => 2/3 quorum survives, cluster writable.
      - Losing az1a (2 Keepers) => only 1/3 Keepers left, quorum BROKEN,
        cluster becomes READ-ONLY until az1a recovers.

    For symmetric "any single AZ can fail" tolerance, run 3 Keepers across
    3 distinct subnet_keys.
  EOT
}

variable "clickhouse_placement" {
  type = map(object({
    subnet_key = string
  }))
  default = {
    "ck-01" = { subnet_key = "az1a" }
    "ck-02" = { subnet_key = "az1c" }
  }
  description = "ClickHouse replicas, keyed by replica name (also used as macros.replica). subnet_key references private_subnet_ids. 2 replicas = tolerate 1 AZ loss."
}

# -------- Private IPs --------
#
# IPs can either be computed from each subnet's CIDR (set host offsets below
# and leave the explicit maps empty — the default), OR the operator can pin
# specific IPs via the maps. The maps win when non-empty.

variable "keeper_ip_host_offset" {
  type        = number
  default     = 100
  description = "Offset into each Keeper subnet's CIDR used by cidrhost() when keeper_private_ips_override is unset. Subnet 10.0.11.0/24 + offset 100 => 10.0.11.100."
}

variable "clickhouse_ip_host_offset" {
  type        = number
  default     = 200
  description = "Offset into each CK subnet's CIDR used by cidrhost() when clickhouse_private_ips_override is unset."
}

variable "keeper_private_ips_override" {
  type        = map(string)
  default     = {}
  description = "Optional: map of keeper name (matches keeper_placement keys) -> explicit private IP. Leave empty to auto-compute via cidrhost(subnet_cidr, keeper_ip_host_offset)."
}

variable "clickhouse_private_ips_override" {
  type        = map(string)
  default     = {}
  description = "Optional: map of replica name (matches clickhouse_placement keys) -> explicit private IP. Leave empty to auto-compute via cidrhost(subnet_cidr, clickhouse_ip_host_offset)."
}

# -------- Instance sizing --------

variable "keeper_instance_type" {
  type        = string
  default     = "t4g.small"
  description = "Keeper nodes don't need much — t4g.small handles Raft for a typical 2-shard / 2-replica cluster. Upshift for >50 replicated tables."
}

variable "clickhouse_instance_type" {
  type        = string
  default     = "r8g.xlarge"
  description = "ClickHouse nodes. r8g = Graviton4 memory-optimized (8 GB/vCPU — CK recommends this ratio for warehousing). r8g.large = cost-optimized MVP (16 GB / 2 vCPU). r8g.xlarge = headroom. Don't use m8g — 4 GB/vCPU is too tight, and 8g.large = 8 GB is below CK's 'total memory should not be below 8GB' floor."
}

# -------- EBS data volume --------

variable "clickhouse_data_volume_gb" {
  type        = number
  default     = 1500
  description = "CK data volume size. gp3 caps at 16 TiB. Online-expandable via `zeelool-ck-resize-data-volume` SSM doc — see plan Appendix C."
}

variable "clickhouse_data_volume_iops" {
  type        = number
  default     = null
  description = "gp3 IOPS override. null = AWS baseline (3000). Range 3000-16000."
}

variable "clickhouse_data_volume_throughput_mbps" {
  type        = number
  default     = null
  description = "gp3 throughput override. null = AWS baseline (125 MB/s). Range 125-1000."
}

# -------- SSH access --------

variable "ssh_key_name" {
  type        = string
  default     = null
  description = "AWS EC2 KeyPair name to attach to every Keeper and CK node for SSH access. null (default) = no key attached, rely on SSM Session Manager. Only the *name* in AWS goes here — the .pem file stays off-repo. NOTE: changing this on a running instance force-recreates it; existing nodes are protected by `ignore_changes = [key_name]`. Retrofit keys onto already-running nodes via scripts/install-ssh-public-key.sh instead."
}

# -------- Backup --------

variable "backup_bucket_name" {
  type        = string
  default     = ""
  description = "S3 bucket for ClickHouse BACKUP TO S3. Leave empty to auto-name as '<name_prefix>-backup-<account_id>-<region>' (globally unique). Set explicitly if you have a naming convention or a pre-existing bucket."
}
