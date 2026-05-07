variable "region" {
  type        = string
  default     = "ap-northeast-1"
  description = "AWS region where the state S3 bucket and lock table will live. Must match the region in envs/prod/backend.hcl."
}

variable "profile" {
  type        = string
  default     = ""
  description = "AWS profile. Empty = resolve via AWS SDK default chain (AWS_PROFILE env, instance profile, SSO)."
}

variable "name_prefix" {
  type        = string
  default     = "zeelool-ck"
  description = "Prefix for the state bucket name (unless overridden) and for AWS tags. Align this with the envs/prod `name_prefix` for readability."
}

variable "state_bucket_name" {
  type        = string
  default     = ""
  description = "S3 bucket for Terraform remote state. Empty = auto-name as '<name_prefix>-tfstate-<region>' (e.g. zeelool-ck-tfstate-ap-northeast-1, zeelool-ck-tfstate-us-west-2). S3 bucket names are globally unique — override when you need a company convention or the default collides."
}

variable "owner" {
  type    = string
  default = "keith"
}
