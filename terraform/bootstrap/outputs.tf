output "state_bucket_name" {
  value       = aws_s3_bucket.tfstate.id
  description = "Remote state S3 bucket — paste into envs/prod/backend.hcl as `bucket`."
}

output "lock_table_name" {
  value       = aws_dynamodb_table.tflock.id
  description = "State lock DynamoDB table — paste into envs/prod/backend.hcl as `dynamodb_table`."
}

output "region" {
  value       = data.aws_region.current.region
  description = "Region where the backend lives — paste into envs/prod/backend.hcl as `region`."
}

# Convenience: the exact content to copy into envs/prod/backend.hcl.
# Customer workflow after `terraform apply` here:
#   terraform output -raw backend_hcl > ../envs/prod/backend.hcl
# Then:
#   cd ../envs/prod
#   AWS_PROFILE=default terraform init -backend-config=backend.hcl
output "backend_hcl" {
  description = "Drop-in content for envs/prod/backend.hcl. Redirect to file with `terraform output -raw backend_hcl > ../envs/prod/backend.hcl`."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.tfstate.id}"
    key            = "envs/prod/terraform.tfstate"
    region         = "${data.aws_region.current.region}"
    dynamodb_table = "${aws_dynamodb_table.tflock.id}"
    encrypt        = true
  EOT
}
