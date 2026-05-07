variable "name" {
  type = string
}

variable "replica_name" {
  type = string
}

variable "shard" {
  type    = string
  default = "01"
}

variable "instance_type" {
  type    = string
  default = "r8g.xlarge"
}

variable "ami_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  type = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "instance_profile_name" {
  type = string
}

variable "root_volume_gb" {
  type    = number
  default = 50
}

variable "data_volume_gb" {
  type        = number
  default     = 1500
  description = "gp3 data volume size. Online expand: bump this var, apply, then run zeelool-ck-resize-data-volume SSM doc on each CK node."
}

variable "data_volume_iops" {
  type        = number
  default     = null
  description = "gp3 IOPS. null = AWS baseline (3000). Range: 3000-16000. Online adjustable."
}

variable "data_volume_throughput_mbps" {
  type        = number
  default     = null
  description = "gp3 throughput in MB/s. null = AWS baseline (125). Range: 125-1000. Online adjustable."
}

variable "availability_zone" {
  type        = string
  description = "AZ for the data volume (must match subnet's AZ)"
}

variable "key_name" {
  type        = string
  default     = null
  description = "EC2 KeyPair name for SSH. null = no key (rely on SSM Session Manager). Changing this on an existing instance force-recreates it — use scripts/install-ssh-public-key.sh to retrofit keys onto already-running nodes instead."
}
