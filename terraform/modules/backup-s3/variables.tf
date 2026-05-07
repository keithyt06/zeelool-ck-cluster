variable "name_prefix" {
  type        = string
  default     = "zeelool-ck"
  description = "Prefix for EventBridge rules, EventBridge IAM role, and default bucket name."
}

variable "bucket_name" {
  type        = string
  default     = ""
  description = "Backup bucket name. Leave empty to auto-name as '<name_prefix>-backup-<account_id>-<region>'. S3 bucket names are globally unique — include account_id when you have no naming convention of your own."
}

variable "schedule_full_cron" {
  type        = string
  default     = "cron(0 17 ? * SUN *)"
  description = "UTC cron for full backups. Default: Sunday 17:00 UTC == Monday 02:00 JST. Change per customer time zone."
}

variable "schedule_incremental_cron" {
  type        = string
  default     = "cron(0 17 ? * MON-SAT *)"
  description = "UTC cron for incremental backups. Default: daily 17:00 UTC."
}

variable "run_backup_doc_name" {
  type        = string
  description = "Name of the SSM Document that executes BACKUP TO S3."
}

variable "ck_primary_instance_id" {
  type        = string
  description = "The single CK replica chosen as backup executor (only one node runs the scheduled backup to avoid contention)."
}

variable "incremental_retention_days" {
  type    = number
  default = 14
}

variable "full_retention_days" {
  type    = number
  default = 28
}

# -------- Alarms --------

variable "alarm_sns_topic_arn" {
  type        = string
  default     = ""
  description = "Optional SNS topic ARN to notify on backup alarms. Empty (default) creates the alarms but does NOT wire a notification action — alarms are still visible in CloudWatch console, just silent. Set this when you have an on-call pipeline (PagerDuty / Opsgenie / email list via SNS)."
}

variable "alarm_actions_enabled" {
  type        = bool
  default     = true
  description = "Whether CloudWatch alarms are enabled. Useful to set false in dev environments where backup failures are expected during setup."
}
