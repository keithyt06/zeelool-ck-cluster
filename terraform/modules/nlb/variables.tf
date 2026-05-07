variable "name_prefix" {
  type        = string
  default     = "zeelool-ck"
  description = "Prefix for NLB name and target group names. NLB final name = '<name_prefix>-nlb'. TG names = '<name_prefix>-nlb-9000' / '-8123'."
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs across AZs"
}

variable "security_group_ids" {
  type = list(string)
}

variable "target_instance_ids" {
  type        = map(string)
  description = "Map of CK node name -> instance ID"
}
