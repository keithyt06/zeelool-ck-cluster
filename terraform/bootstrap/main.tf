# ============================================================================
# Terraform state backend bootstrap
#
# Creates:
#   1. S3 bucket for remote state (versioned + SSE + public-access-block)
#   2. DynamoDB table for state locking
#
# Apply ONCE per account+region before deploying envs/prod:
#
#   cd terraform/bootstrap
#   cp terraform.tfvars.example terraform.tfvars   # optional, defaults are fine
#   AWS_PROFILE=default terraform init
#   AWS_PROFILE=default terraform apply
#
# After apply, `terraform output backend_hcl` prints the exact content to
# paste into `../envs/prod/backend.hcl` so the main infra can init its backend.
# ============================================================================

data "aws_region" "current" {}

locals {
  # Default bucket name: "<name_prefix>-tfstate-<region>" — e.g.
  # "zeelool-ck-tfstate-ap-northeast-1". S3 bucket names are global, so the
  # region suffix keeps the same module usable in multiple regions without
  # collision. S3 bucket names allow dashes so we keep the literal region.
  #
  # NOTE: account_id is deliberately NOT in the default — S3 leaks bucket
  # names via 403 vs 404, and adding account_id to the bucket name would
  # leak your account_id to anyone probing. If you need that guard you can
  # set `state_bucket_name` explicitly to "<acct>-<prefix>-tfstate".
  effective_state_bucket_name = (
    var.state_bucket_name != ""
    ? var.state_bucket_name
    : "${var.name_prefix}-tfstate-${data.aws_region.current.region}"
  )

  effective_lock_table_name = (
    var.lock_table_name != ""
    ? var.lock_table_name
    : "${var.name_prefix}-tflock"
  )
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.effective_state_bucket_name

  # Bootstrap is conservative — block accidental terraform destroy of the
  # bucket that holds state for every OTHER stack in this project.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = local.effective_state_bucket_name }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = local.effective_lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Same guard as the S3 bucket — losing this table corrupts state locking.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = local.effective_lock_table_name }
}
