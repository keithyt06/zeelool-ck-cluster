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

  # Partial backend configuration — values supplied at init time via
  # `-backend-config=backend.hcl`. Template: backend.hcl.example.
  # Real values: backend.hcl (gitignored).
  #
  # The state bucket + lock table are created ONCE by `terraform/bootstrap/`
  # — see its README. After that:
  #
  #   AWS_PROFILE=default terraform init -backend-config=backend.hcl
  #
  # Subsequent `terraform plan/apply` runs reuse cached config from `.terraform/`.
  #
  # Credentials resolve from the ambient AWS config chain (AWS_PROFILE env,
  # instance profile, SSO) — backend has no hardcoded profile.
  backend "s3" {}
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
