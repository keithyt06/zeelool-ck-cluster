variable "name_prefix" {
  type        = string
  default     = "zeelool-ck"
  description = "Prefix for IAM role and instance profile names."
}

variable "backup_bucket_arn" {
  type        = string
  description = "Backup bucket ARN for S3 PutObject/GetObject. Only referenced when enable_backup_policy = true."
  default     = ""
}

variable "enable_backup_policy" {
  type        = bool
  default     = true
  description = "Attach the S3 backup policy to the CK data-node role. Set false for a deployment without backup (bootstrap / dev). When true, backup_bucket_arn must be non-empty. Plan-safe boolean so `count` resolves at plan time even when the bucket ARN is known-after-apply."
}
