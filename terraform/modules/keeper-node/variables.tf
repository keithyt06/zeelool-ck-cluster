variable "name" {
  type        = string
  description = "Hostname-friendly node name, e.g. keeper-01"
}

variable "server_id" {
  type        = number
  description = "Keeper Raft server_id, 1..3"
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
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

variable "key_name" {
  type        = string
  default     = null
  description = "EC2 KeyPair name for SSH. null = no key (rely on SSM Session Manager). Changing this on an existing instance force-recreates it — use scripts/install-ssh-public-key.sh to retrofit keys onto already-running nodes instead."
}
