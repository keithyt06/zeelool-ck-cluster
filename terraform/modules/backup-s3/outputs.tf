output "bucket_arn" {
  value = aws_s3_bucket.backup.arn
}

output "bucket_name" {
  value = aws_s3_bucket.backup.id
}
