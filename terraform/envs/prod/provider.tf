terraform {
  # Pin to AWS provider v6.x. State on this backend was written by v6 (v6
  # introduced per-resource `region` attributes v5 can't read), so downgrading
  # breaks with "unsupported attribute" errors on every resource. Use v6.
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend credentials resolve from the ambient AWS config chain (AWS_PROFILE
  # env var, instance profile, SSO) so the same state is usable from CI, laptops,
  # and other operators without a hard-coded profile name.
  backend "s3" {
    bucket         = "zeelool-ck-tfstate-apne1"
    key            = "envs/prod/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "zeelool-ck-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  # profile is optional — when unset, the AWS SDK resolves creds via
  # AWS_PROFILE / instance profile / SSO / env vars. Override via
  # -var profile=... if you really need a named profile.
  profile = var.profile != "" ? var.profile : null

  default_tags {
    tags = merge(
      {
        Project     = var.name_prefix
        Environment = var.environment
        ManagedBy   = "terraform"
        Owner       = var.owner
      },
      var.extra_tags,
    )
  }
}
