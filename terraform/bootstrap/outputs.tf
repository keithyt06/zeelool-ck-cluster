output "state_bucket_name" {
  value       = aws_s3_bucket.tfstate.id
  description = "Remote state S3 bucket — paste into envs/prod/backend.hcl as `bucket`."
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
#
# Uses `use_lockfile = true` (S3 native locking, Terraform 1.10+) instead
# of the deprecated `dynamodb_table` arg. Locking happens via a sibling
# `.tflock` object in the same bucket — zero extra AWS resources.
output "backend_hcl" {
  description = "Drop-in content for envs/prod/backend.hcl. Redirect to file with `terraform output -raw backend_hcl > ../envs/prod/backend.hcl`."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.tfstate.id}"
    key          = "envs/prod/terraform.tfstate"
    region       = "${data.aws_region.current.region}"
    use_lockfile = true
    encrypt      = true
  EOT
}
