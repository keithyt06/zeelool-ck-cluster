output "bucket_arn" {
  value = aws_s3_bucket.backup.arn
}

output "bucket_name" {
  value = aws_s3_bucket.backup.id
}

output "alarm_names" {
  description = "Names of CloudWatch alarms created for this backup pipeline. Wire these into a dashboard or query via `aws cloudwatch describe-alarms --alarm-names`."
  value = concat(
    [for k, a in aws_cloudwatch_metric_alarm.backup_eb_failures : a.alarm_name],
    [aws_cloudwatch_metric_alarm.backup_ssm_failures.alarm_name],
  )
}
