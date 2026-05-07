data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  effective_bucket_name = (
    var.bucket_name != ""
    ? var.bucket_name
    : "${var.name_prefix}-backup-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  )
}

resource "aws_s3_bucket" "backup" {
  bucket = local.effective_bucket_name

  tags = { Name = local.effective_bucket_name }
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "incremental-expire"
    status = "Enabled"
    filter { prefix = "incremental/" }
    expiration { days = var.incremental_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  rule {
    id     = "full-expire"
    status = "Enabled"
    filter { prefix = "full/" }
    expiration { days = var.full_retention_days }
    noncurrent_version_expiration { noncurrent_days = 14 }
  }

  # Clean up orphaned multipart uploads from ClickHouse BACKUP failures.
  # Without this, failed multi-GB backups leave partial parts billing forever.
  rule {
    id     = "abort-orphan-mpu"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# EventBridge IAM role to invoke SSM SendCommand
data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  name               = "${var.name_prefix}-backup-events"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "events" {
  statement {
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:document/${var.run_backup_doc_name}",
      "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/${var.ck_primary_instance_id}",
    ]
  }
}

resource "aws_iam_role_policy" "events" {
  name   = "${var.name_prefix}-backup-events"
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.events.json
}

resource "aws_cloudwatch_event_rule" "full" {
  name                = "${var.name_prefix}-backup-full"
  description         = "Weekly full backup"
  schedule_expression = var.schedule_full_cron
}

resource "aws_cloudwatch_event_rule" "incremental" {
  name                = "${var.name_prefix}-backup-incremental"
  description         = "Daily incremental backup"
  schedule_expression = var.schedule_incremental_cron
}

resource "aws_cloudwatch_event_target" "full" {
  rule     = aws_cloudwatch_event_rule.full.name
  arn      = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:document/${var.run_backup_doc_name}"
  role_arn = aws_iam_role.events.arn

  run_command_targets {
    key    = "InstanceIds"
    values = [var.ck_primary_instance_id]
  }

  input = jsonencode({
    BucketName = [local.effective_bucket_name]
    BackupType = ["full"]
    BackupDate = ["<aws.events.event.ingestion-time>"]
  })
}

resource "aws_cloudwatch_event_target" "incremental" {
  rule     = aws_cloudwatch_event_rule.incremental.name
  arn      = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:document/${var.run_backup_doc_name}"
  role_arn = aws_iam_role.events.arn

  run_command_targets {
    key    = "InstanceIds"
    values = [var.ck_primary_instance_id]
  }

  input = jsonencode({
    BucketName = [local.effective_bucket_name]
    BackupType = ["incremental"]
    BackupDate = ["<aws.events.event.ingestion-time>"]
  })
}

# -------- CloudWatch alarms --------
#
# Two alarms catch the common failure classes:
#
# 1. EventBridge FailedInvocations — when EB can't hand off to SSM (IAM drift,
#    target instance terminated, SSM Document deleted). Fast signal: fires
#    within minutes of the scheduled cron trigger.
#
# 2. SSM CommandsFailed on the run-backup document — when EB successfully
#    invokes SSM but the backup command itself fails (CK down, S3 perms,
#    disk full, base_backup mismatch on incremental). This is the "backup
#    script ran and errored" case.
#
# Alarms are created regardless of whether a notification target is set.
# If alarm_sns_topic_arn is empty, the alarm is visible in CloudWatch but
# doesn't page anyone — good MVP default, zero cost.

locals {
  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
}

resource "aws_cloudwatch_metric_alarm" "backup_eb_failures" {
  for_each = {
    full        = aws_cloudwatch_event_rule.full.name
    incremental = aws_cloudwatch_event_rule.incremental.name
  }

  alarm_name          = "${var.name_prefix}-backup-${each.key}-eb-failed"
  alarm_description   = "EventBridge rule ${each.value} failed to invoke SSM — usually IAM drift, missing instance, or deleted Document. Last-successful-backup chain at risk."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  treat_missing_data  = "notBreaching"

  metric_name = "FailedInvocations"
  namespace   = "AWS/Events"
  period      = 300
  statistic   = "Sum"
  dimensions = {
    RuleName = each.value
  }

  actions_enabled = var.alarm_actions_enabled
  alarm_actions   = local.alarm_actions
  ok_actions      = local.alarm_actions

  tags = { Name = "${var.name_prefix}-backup-${each.key}-eb-failed" }
}

resource "aws_cloudwatch_metric_alarm" "backup_ssm_failures" {
  alarm_name          = "${var.name_prefix}-backup-ssm-command-failed"
  alarm_description   = "SSM RunCommand on ${var.run_backup_doc_name} failed. Backup did NOT complete — check command history + CK-node logs."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  treat_missing_data  = "notBreaching"

  metric_name = "CommandsFailed"
  namespace   = "AWS/SSM-RunCommand"
  period      = 300
  statistic   = "Sum"
  dimensions = {
    DocumentName = var.run_backup_doc_name
  }

  actions_enabled = var.alarm_actions_enabled
  alarm_actions   = local.alarm_actions
  ok_actions      = local.alarm_actions

  tags = { Name = "${var.name_prefix}-backup-ssm-command-failed" }
}
