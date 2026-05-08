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
CLUSTER_NAME=$(terraform -chdir=terraform/envs/prod output -raw cluster_name)
BACKUP_BUCKET=$(terraform -chdir=terraform/envs/prod output -raw backup_bucket_name 2>/dev/null || echo "<unset>")
ACCOUNT_ID=$(aws --region "$REGION" sts get-caller-identity --query Account --output text 2>/dev/null || echo "<unknown>")

# Fetch the generated password from SSM. Printed inline so the operator has
# everything in one block — same password is already stored in SSM Parameter
# Store (SecureString), so re-reading it anytime via `aws ssm get-parameter`
# gives the same value. If the current stdout is piped to a log file, make
# sure access to that log is controlled.
PASS=$(aws --region "$REGION" ssm get-parameter \
  --name "/${NAME_PREFIX}/default-user-password" \
  --with-decryption --query Parameter.Value --output text 2>/dev/null \
  || echo "<fetch-failed — run the command under 'Fetch password' below>")

cat <<SUMMARY

  ─────────────────── CLUSTER INFO ───────────────────
  AWS account    : $ACCOUNT_ID
  Region         : $REGION
  Name prefix    : $NAME_PREFIX
  Cluster name   : $CLUSTER_NAME

  ─────────────────── CONNECT ────────────────────────
  NLB DNS        : $NLB_DNS
  Native TCP     : $NLB_DNS:9000
  HTTP           : $NLB_DNS:8123

  Username       : default
  Password       : $PASS

  Example (from a VPC-internal host):
    clickhouse-client --host $NLB_DNS \\
      --user default --password '$PASS' \\
      --query 'SELECT version(), hostName()'

    curl -u "default:$PASS" \\
      "http://$NLB_DNS:8123/?query=SELECT+1"

  ─────────────────── REFETCH PASSWORD (if lost) ─────
  aws --region $REGION ssm get-parameter \\
    --name /$NAME_PREFIX/default-user-password \\
    --with-decryption --query Parameter.Value --output text

  ─────────────────── BACKUP ─────────────────────────
  Bucket         : $BACKUP_BUCKET
  Schedule       : full Sun 17:00 UTC · incremental MON-SAT 17:00 UTC
  Alarms         : terraform -chdir=terraform/envs/prod output backup_alarm_names

  ─────────────────── TEARDOWN (destructive) ─────────
  ./scripts/teardown.sh

  ⚠ Password is printed above in clear text. If this terminal output is
    captured in a log / CI artifact, review access control on that artifact.
    Rotate the password by writing a new value to the SSM parameter and
    re-running ./scripts/render-and-push-ck-config.sh.
SUMMARY
