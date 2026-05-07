#!/bin/bash
#
# End-to-end post-apply bootstrap. After `terraform apply` creates the EC2
# instances, run this ONE command to install binaries, render configs, and
# verify the cluster.
#
# Steps (all idempotent — safe to re-run):
#   1. Install Keeper binary on every keeper node (parallel SSM SendCommand)
#   2. Render + push keeper_config.xml per keeper
#   3. Wait for Keeper quorum (read zk_server_state via mntr)
#   4. Install ClickHouse binary on every CK node (parallel SSM SendCommand)
#   5. Ensure default-user password exists in SSM Parameter Store
#      (prompts to generate one the first time)
#   6. Render + push CK configs (calls scripts/render-and-push-ck-config.sh)
#   7. Final smoke (calls scripts/smoke.sh)
#
# Optional env:
#   AWS_PROFILE           — passed through to aws
#   ACK_PASSWORD_SAVED=1  — skip interactive "press Enter after saving password"
#                           prompt in step 5 (for CI/automation). First-run
#                           password is still printed to stdout — make sure
#                           the invoking pipeline captures it.
#
# Usage:
#   ./scripts/bootstrap-post-apply.sh

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
cd terraform/envs/prod

# -------- Pull topology --------

INFO=$(terraform output -no-color -json cluster_info 2>/dev/null \
  | sed '/^$/,$d')

if [ -z "$INFO" ]; then
  echo "ERROR: terraform output cluster_info is empty. Run 'terraform apply' first." >&2
  exit 1
fi

REGION=$(jq -r '.region' <<<"$INFO")
NAME_PREFIX=$(jq -r '.name_prefix' <<<"$INFO")
DOC_INSTALL_KEEPER=$(jq -r '.ssm_docs.install_keeper' <<<"$INFO")
DOC_INSTALL_CK=$(jq -r '.ssm_docs.install_clickhouse' <<<"$INFO")

AWS_FLAGS=(--region "$REGION")
if [ -n "${AWS_PROFILE:-}" ]; then AWS_FLAGS+=(--profile "$AWS_PROFILE"); fi

mapfile -t KEEPER_IDS < <(jq -r '.keepers     | to_entries | .[].value.instance_id' <<<"$INFO")
mapfile -t CK_IDS     < <(jq -r '.clickhouses | to_entries | .[].value.instance_id' <<<"$INFO")
KEEPER01_ID=$(jq -r '.keepers | to_entries | sort_by(.value.server_id) | .[0].value.instance_id' <<<"$INFO")

echo "============================================================"
echo " Cluster bootstrap: $NAME_PREFIX ($REGION)"
echo "   Keepers: ${#KEEPER_IDS[@]}  CKs: ${#CK_IDS[@]}"
echo "============================================================"

# -------- Helper: fan-out SSM SendCommand and wait --------

ssm_fanout() {
  local doc="$1"; shift
  local label="$1"; shift
  local extra_params="${1:-}"; shift || true
  local ids=("$@")
  local cmd_ids=()

  echo
  echo "--- $label (doc=$doc, targets=${#ids[@]}) ---"
  for iid in "${ids[@]}"; do
    local params_flag=()
    if [ -n "$extra_params" ]; then params_flag=(--parameters "$extra_params"); fi
    cmd=$(aws "${AWS_FLAGS[@]}" ssm send-command \
      --document-name "$doc" \
      --instance-ids "$iid" \
      "${params_flag[@]}" \
      --query 'Command.CommandId' --output text)
    cmd_ids+=("$iid:$cmd")
    echo "  $iid → cmd=$cmd"
  done

  local fail=0
  for entry in "${cmd_ids[@]}"; do
    iid=${entry%:*}; cmd=${entry#*:}
    aws "${AWS_FLAGS[@]}" ssm wait command-executed \
      --command-id "$cmd" --instance-id "$iid" 2>/dev/null || true
    status=$(aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
      --command-id "$cmd" --instance-id "$iid" \
      --query 'Status' --output text)
    echo "  $iid → $status"
    if [ "$status" != "Success" ]; then
      fail=1
      aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
        --command-id "$cmd" --instance-id "$iid" \
        --query 'StandardErrorContent' --output text >&2 || true
    fi
  done
  if [ "$fail" != 0 ]; then
    echo "ERROR: $label had failures — aborting." >&2
    exit 1
  fi
}

# -------- 1. Install Keeper binary --------

ssm_fanout "$DOC_INSTALL_KEEPER" "1/7 Install Keeper binary" "" "${KEEPER_IDS[@]}"

# -------- 2. Render + push keeper_config.xml --------

echo
echo "--- 2/7 Render + push keeper configs ---"
"$REPO_ROOT/scripts/render-and-push-keeper-config.sh"

# -------- 3. Wait for Keeper quorum --------

echo
echo "--- 3/7 Wait for Keeper quorum (up to 60s) ---"
for attempt in $(seq 1 12); do
  cmd=$(aws "${AWS_FLAGS[@]}" ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$KEEPER01_ID" \
    --parameters 'commands=["which ncat >/dev/null 2>&1 || dnf install -y nmap-ncat >/dev/null 2>&1","(echo mntr; sleep 1) | ncat -i 1 localhost 9181 2>/dev/null | grep zk_server_state || echo zk_server_state=unknown"]' \
    --query 'Command.CommandId' --output text)
  aws "${AWS_FLAGS[@]}" ssm wait command-executed \
    --command-id "$cmd" --instance-id "$KEEPER01_ID" 2>/dev/null || true
  out=$(aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
    --command-id "$cmd" --instance-id "$KEEPER01_ID" \
    --query 'StandardOutputContent' --output text | tr -d '\r\n')
  echo "  attempt $attempt: $out"
  # Keeper's mntr output separates key/value with TAB ("zk_server_state\tfollower"),
  # not '='. Use wildcard *zk_server_state* to match both TAB and '=' forms.
  case "$out" in
    *zk_server_state*leader*|*zk_server_state*follower*)
      echo "  ✓ quorum formed"
      break
      ;;
  esac
  if [ "$attempt" = 12 ]; then
    echo "ERROR: Keeper quorum did not form in 60s. Inspect with scripts/smoke.sh §3." >&2
    exit 1
  fi
  sleep 5
done

# -------- 4. Install CK binary --------

ssm_fanout "$DOC_INSTALL_CK" "4/7 Install ClickHouse binary" "" "${CK_IDS[@]}"

# -------- 5. Ensure default-user password in SSM Parameter Store --------

PASS_PARAM="/${NAME_PREFIX}/default-user-password"
echo
echo "--- 5/7 Default-user password ---"
if aws "${AWS_FLAGS[@]}" ssm get-parameter \
   --name "$PASS_PARAM" --with-decryption >/dev/null 2>&1; then
  echo "  ✓ $PASS_PARAM already set — reusing."
else
  echo "  $PASS_PARAM not set. Generating a random 32-char password..."
  PASS=$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)
  aws "${AWS_FLAGS[@]}" ssm put-parameter \
    --name "$PASS_PARAM" --type SecureString --value "$PASS" \
    --description "ClickHouse default user password ($NAME_PREFIX)" >/dev/null
  echo
  echo "  ================================================================"
  echo "  SAVE THIS PASSWORD NOW — it is NOT stored anywhere except SSM:"
  echo "    $PASS"
  echo "  ================================================================"
  echo "  (you can always read it back with:"
  echo "    aws --region $REGION ssm get-parameter --name $PASS_PARAM \\"
  echo "      --with-decryption --query Parameter.Value --output text)"
  echo
  # Skip interactive prompt when ACK_PASSWORD_SAVED=1 (CI) or stdin is not a tty.
  if [ "${ACK_PASSWORD_SAVED:-0}" = "1" ] || [ ! -t 0 ]; then
    echo "  (non-interactive: skipping press-Enter acknowledgement)"
  else
    read -rp "  Press Enter after saving it to your password manager... " _
  fi
fi

# -------- 6. Render + push CK configs --------

echo
echo "--- 6/7 Render + push CK configs ---"
"$REPO_ROOT/scripts/render-and-push-ck-config.sh"

# -------- 7. Final smoke --------

echo
echo "--- 7/7 Smoke test ---"
"$REPO_ROOT/scripts/smoke.sh"

echo
echo "============================================================"
echo " ✓ Bootstrap complete."
echo "   NLB DNS: $(jq -r '.nlb_dns' <<<"$INFO")"
echo "   (Connect VPC-internal clients to <NLB>:9000 for native protocol, <NLB>:8123 for HTTP)"
echo "   Backup bucket: $(jq -r '.backup' <<<"$INFO")"
echo "   First backup: follow CUSTOMER-ONBOARDING.md §6 or wait for"
echo "                 the next EventBridge schedule trigger."
echo "============================================================"
