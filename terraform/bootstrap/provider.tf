terraform {
  # Bootstrap state is local on purpose — this is what creates the remote
  # S3/DynamoDB backend that `envs/prod` uses. Chicken-and-egg: you can't
  # store the creation of the state bucket IN the state bucket itself.
  #
  # Commit the resulting `terraform.tfstate` (it's tiny, contains only
  # backend infra IDs) or keep it local. Either way, it's NOT sensitive
  # — the S3/DDB resources it tracks are discoverable via AWS console.
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile != "" ? var.profile : null

  default_tags {
    tags = {
      Project     = var.name_prefix
      Environment = "shared"
      ManagedBy   = "terraform-bootstrap"
      Owner       = var.owner
    }
  }
}
