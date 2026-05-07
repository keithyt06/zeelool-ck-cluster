#!/bin/bash
#
# One-command deploy — chains the 4 deployment phases.
#
# Pre-req (NOT automated): VPC + 2+ private subnets exist in your target region,
# and tfvars are filled in:
#   terraform/bootstrap/terraform.tfvars     (copy from .example, pick region + profile)
#   terraform/envs/prod/terraform.tfvars     (copy from .example, fill vpc_id + subnets)
#
# Then:
#   export AWS_PROFILE=<your-profile>
#   ./deploy.sh
#
# Flags:
#   --skip-preflight   skip ./preflight.sh (for CI where VPC is pre-verified)
#   --auto-approve     pass -auto-approve to terraform apply (default: interactive prompt)
#   --skip-smoke       skip final smoke test (for faster iteration on bootstrap steps)
#
# Idempotent: safe to re-run. Each phase is itself idempotent.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$REPO_ROOT"

SKIP_PREFLIGHT=0
SKIP_SMOKE=0
AUTO_APPROVE=""
for arg in "$@"; do
  case "$arg" in
    --skip-preflight) SKIP_PREFLIGHT=1 ;;
    --auto-approve)   AUTO_APPROVE="-auto-approve" ;;
    --skip-smoke)     SKIP_SMOKE=1 ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# //;s/^#//' | head -30
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

say() { echo; echo "=== $* ==="; }

# -------- Phase 0: pre-flight --------
if [ "$SKIP_PREFLIGHT" = "0" ]; then
  say "Phase 0: Pre-flight"
  ./preflight.sh
else
  echo "Phase 0 pre-flight skipped (--skip-preflight)"
fi

# -------- Phase 1: bootstrap state backend --------
say "Phase 1: Bootstrap state backend (S3 + S3 native lock)"
pushd terraform/bootstrap >/dev/null
terraform init -input=false
if [ -n "$AUTO_APPROVE" ]; then
  terraform apply $AUTO_APPROVE
else
  terraform apply
fi
terraform output -raw backend_hcl > ../envs/prod/backend.hcl
echo "  wrote ../envs/prod/backend.hcl:"
sed 's/^/    /' ../envs/prod/backend.hcl
popd >/dev/null

# -------- Phase 2: main infra --------
say "Phase 2: Main infrastructure (VPC resources, EC2, NLB, S3, IAM, SSM, CW)"
pushd terraform/envs/prod >/dev/null
terraform init -input=false -reconfigure -backend-config=backend.hcl
terraform plan -input=false -out=p.plan
if [ -n "$AUTO_APPROVE" ]; then
  terraform apply $AUTO_APPROVE p.plan
else
  echo
  echo "Review plan above. Press Enter to apply, or Ctrl-C to abort:"
  read -r _ < /dev/tty
  terraform apply p.plan
fi
rm -f p.plan
popd >/dev/null

# -------- Phase 3: CK software bootstrap --------
say "Phase 3: ClickHouse + Keeper software layer"
ACK_PASSWORD_SAVED=1 ./scripts/bootstrap-post-apply.sh

# -------- Phase 4: smoke --------
if [ "$SKIP_SMOKE" = "0" ]; then
  say "Phase 4: Smoke test"
  ./scripts/smoke.sh
fi

# -------- Summary --------
say "Deployment complete"
NLB_DNS=$(terraform -chdir=terraform/envs/prod output -raw clickhouse_nlb_dns)
REGION=$(terraform -chdir=terraform/envs/prod output -raw region)
NAME_PREFIX=$(terraform -chdir=terraform/envs/prod output -raw name_prefix)
cat <<SUMMARY

  NLB DNS:       $NLB_DNS
  Region:        $REGION
  Name prefix:   $NAME_PREFIX

  Fetch default-user password:
    aws --region $REGION ssm get-parameter \\
      --name /$NAME_PREFIX/default-user-password \\
      --with-decryption --query Parameter.Value --output text

  Connect (from a VPC-internal host):
    clickhouse-client --host $NLB_DNS --user default --password '<pass>' --query 'SELECT 1'

  CloudWatch alarm names:
    terraform -chdir=terraform/envs/prod output backup_alarm_names

  Teardown (destructive):
    ./scripts/teardown.sh

SUMMARY
