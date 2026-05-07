#!/bin/bash
#
# Pre-flight check for deploy.sh. Runs a handful of fast assertions and
# exits non-zero if anything is wrong, so deploy.sh can bail early before
# touching AWS.
#
# Validates:
#   1. AWS CLI reachable + authenticated (sts get-caller-identity works)
#   2. Required tfvars files exist (or can be bootstrapped from .example)
#   3. Required tools: terraform (>= 1.10 for use_lockfile), jq, aws
#   4. VPC + subnets referenced in envs/prod/terraform.tfvars actually exist
#      in the target region
#   5. Subnets look private (no public IP on launch)
#
# No AWS writes — all describe-* read-only calls.
#
# Exits 0 on success, non-zero on failure. Prints a summary either way.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$REPO_ROOT"

fail() { echo "  ✗ $*" >&2; ERRS=$((ERRS + 1)); }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*" >&2; }

ERRS=0
echo "=== Pre-flight checks ==="

# -------- 1. Tools --------
echo
echo "[1/5] Local tools"
for t in terraform aws jq; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t found: $(command -v "$t")"
  else
    fail "$t not installed"
  fi
done
# Terraform >= 1.10 needed for `use_lockfile`
if command -v terraform >/dev/null 2>&1; then
  TF_VER=$(terraform version -json 2>/dev/null | jq -r .terraform_version 2>/dev/null || echo 0.0.0)
  TF_MAJOR=$(echo "$TF_VER" | cut -d. -f1)
  TF_MINOR=$(echo "$TF_VER" | cut -d. -f2)
  if [ "$TF_MAJOR" -gt 1 ] || { [ "$TF_MAJOR" = "1" ] && [ "$TF_MINOR" -ge 10 ]; }; then
    ok "terraform $TF_VER (>= 1.10 required for use_lockfile)"
  else
    fail "terraform $TF_VER — need >= 1.10 (S3 native locking)"
  fi
fi

# -------- 2. AWS auth --------
echo
echo "[2/5] AWS credentials"
if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  warn "neither \$AWS_PROFILE nor \$AWS_ACCESS_KEY_ID set — SDK will try default chain"
fi
if IDENT=$(aws sts get-caller-identity --output json 2>/dev/null); then
  ACCOUNT=$(jq -r .Account <<<"$IDENT")
  ARN=$(jq -r .Arn <<<"$IDENT")
  ok "account=$ACCOUNT"
  ok "caller=$ARN"
  ok "profile=${AWS_PROFILE:-<ambient>}"
else
  fail "aws sts get-caller-identity failed — check \$AWS_PROFILE or run 'aws configure'"
fi

# -------- 3. tfvars files --------
echo
echo "[3/5] Required tfvars"
BOOT_TFVARS="terraform/bootstrap/terraform.tfvars"
PROD_TFVARS="terraform/envs/prod/terraform.tfvars"

for f in "$BOOT_TFVARS" "$PROD_TFVARS"; do
  if [ -f "$f" ]; then
    ok "$f present"
  elif [ -f "${f}.example" ]; then
    fail "$f missing — cp ${f}.example $f and fill it in first"
  else
    fail "$f and ${f}.example both missing — repo state bad"
  fi
done

# -------- 4. envs/prod required vars present --------
echo
echo "[4/5] envs/prod required fields"
if [ -f "$PROD_TFVARS" ]; then
  for req in vpc_id private_subnet_ids; do
    if grep -qE "^\s*${req}\s*=" "$PROD_TFVARS"; then
      ok "$req set"
    else
      fail "$PROD_TFVARS missing required field: $req"
    fi
  done
fi

# -------- 5. VPC + subnets resolvable --------
echo
echo "[5/5] VPC + subnet reachability"
if [ -f "$PROD_TFVARS" ] && [ "$ERRS" = 0 ]; then
  # Resolve region (tfvars > AWS_REGION env > AWS_DEFAULT_REGION > empty)
  TFVARS_REGION=$(grep -E '^\s*region\s*=' "$PROD_TFVARS" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true)
  REGION="${TFVARS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
  if [ -z "$REGION" ]; then
    fail "region unresolvable — set in $PROD_TFVARS or export \$AWS_REGION"
  else
    ok "region=$REGION"

    VPC_ID=$(grep -E '^\s*vpc_id\s*=' "$PROD_TFVARS" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true)
    if [ -n "$VPC_ID" ]; then
      if aws --region "$REGION" ec2 describe-vpcs --vpc-ids "$VPC_ID" >/dev/null 2>&1; then
        ok "VPC $VPC_ID exists in $REGION"
      else
        fail "VPC $VPC_ID not found in $REGION (wrong region? wrong profile? VPC deleted?)"
      fi
    fi

    # Extract subnet IDs (grep lines like `"az1a" = "subnet-XXX"`)
    SUBNETS=$(grep -oE 'subnet-[0-9a-f]+' "$PROD_TFVARS" | sort -u || true)
    if [ -n "$SUBNETS" ]; then
      for s in $SUBNETS; do
        if aws --region "$REGION" ec2 describe-subnets --subnet-ids "$s" >/dev/null 2>&1; then
          MAP_PUBLIC=$(aws --region "$REGION" ec2 describe-subnets --subnet-ids "$s" \
            --query 'Subnets[0].MapPublicIpOnLaunch' --output text)
          if [ "$MAP_PUBLIC" = "True" ]; then
            warn "$s has MapPublicIpOnLaunch=true — looks PUBLIC. CK should be on private subnets."
          else
            ok "subnet $s exists (private)"
          fi
        else
          fail "subnet $s not found in $REGION"
        fi
      done
    fi
  fi
fi

# -------- Summary --------
echo
if [ "$ERRS" = 0 ]; then
  echo "=== ✓ Pre-flight OK — safe to run ./deploy.sh ==="
  exit 0
else
  echo "=== ✗ Pre-flight failed: $ERRS error(s) — fix above before deploying ==="
  exit 1
fi
