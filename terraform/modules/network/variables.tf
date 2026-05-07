variable "vpc_id" {
  type        = string
  description = "VPC the CK stack is deployed into."
}

variable "name_prefix" {
  type        = string
  default     = "zeelool-ck"
  description = "Prefix for SG names and endpoint tags."
}

variable "private_route_table_ids" {
  type        = list(string)
  description = "Private route table IDs to associate with the S3 gateway endpoint. Typically derived by the caller from the CK subnets (see envs/prod/main.tf)."
}
