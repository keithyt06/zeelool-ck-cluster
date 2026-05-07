#!/bin/bash
#
# End-to-end smoke test. Verifies SSM reachability, Keeper quorum, CK cluster
# membership, NLB target health, backup bucket state, and EventBridge rules.
#
# Zero hardcoded region / profile / IP / instance ID — everything read from
# `terraform output -json cluster_info`.
#
# Optional env vars:
#   AWS_PROFILE — adds --profile <x> to every aws call.

set -euo pipefail

cd "$(dirname "$0")/../terraform/envs/prod"

# Terraform may append deprecation warnings after the JSON payload on stdout;
# trim to the balanced top-level `{...}` block so jq doesn't choke.
INFO=$(terraform output -no-color -json cluster_info 2>/dev/null \
  | awk '/^{/{p=1} p{print} /^}$/{exit}')
REGION=$(jq -r '.region' <<<"$INFO")
NAME_PREFIX=$(jq -r '.name_prefix' <<<"$INFO")
CLUSTER_NAME=$(jq -r '.cluster_name' <<<"$INFO")

AWS_FLAGS=(--region "$REGION")
if [ -n "${AWS_PROFILE:-}" ]; then AWS_FLAGS+=(--profile "$AWS_PROFILE"); fi

echo "=== 0. Cluster ==="
echo "region=$REGION | prefix=$NAME_PREFIX | cluster=$CLUSTER_NAME"

echo
echo "=== 1. Terraform outputs ==="
terraform output

echo
echo "=== 2. SSM instances online ==="
CK_IDS=$(jq -r '.clickhouses | to_entries | map(.value.instance_id) | join(",")' <<<"$INFO")
KP_IDS=$(jq -r '.keepers     | to_entries | map(.value.instance_id) | join(",")' <<<"$INFO")
INSTANCES="${CK_IDS},${KP_IDS}"
aws "${AWS_FLAGS[@]}" ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${INSTANCES}" \
  --query 'InstanceInformationList[].{Id:InstanceId,Status:PingStatus,Name:ComputerName}' \
  --output table

echo
echo "=== 3. Keeper quorum ==="
KEEPER01=$(jq -r '.keepers | to_entries | sort_by(.key) | .[0].value.instance_id' <<<"$INFO")
CMD=$(aws "${AWS_FLAGS[@]}" ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$KEEPER01" \
  --parameters 'commands=["which ncat >/dev/null 2>&1 || dnf install -y nmap-ncat >/dev/null","(echo mntr; sleep 1) | ncat -i 1 localhost 9181 | grep -E \"zk_server_state|zk_followers|zk_synced_followers\""]' \
  --query 'Command.CommandId' --output text)
aws "${AWS_FLAGS[@]}" ssm wait command-executed --command-id "$CMD" --instance-id "$KEEPER01" 2>/dev/null || true
aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
  --command-id "$CMD" --instance-id "$KEEPER01" \
  --query 'StandardOutputContent' --output text

echo
echo "=== 4. CK replicas healthy ==="
CK01=$(jq -r '.clickhouses | to_entries | sort_by(.key) | .[0].value.instance_id' <<<"$INFO")
SQL_B64=$(base64 -w0 <<EOF
SELECT host_name, is_local FROM system.clusters WHERE cluster = '${CLUSTER_NAME}' FORMAT TSV;
EOF
)
CMD=$(aws "${AWS_FLAGS[@]}" ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CK01" \
  --parameters "commands=[\"echo '${SQL_B64}' | base64 -d | clickhouse-client --multiquery\"]" \
  --query 'Command.CommandId' --output text)
aws "${AWS_FLAGS[@]}" ssm wait command-executed --command-id "$CMD" --instance-id "$CK01" 2>/dev/null || true
aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
  --command-id "$CMD" --instance-id "$CK01" \
  --query 'StandardOutputContent' --output text

echo
echo "=== 5. NLB target health ==="
for port in 9000 8123; do
  TG=$(aws "${AWS_FLAGS[@]}" elbv2 describe-target-groups \
    --names "${NAME_PREFIX}-nlb-${port}" --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo "--- TG ${NAME_PREFIX}-nlb-${port} ---"
  aws "${AWS_FLAGS[@]}" elbv2 describe-target-health \
    --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State}' --output table
done

echo
echo "=== 6. Backup S3 bucket ==="
BUCKET=$(jq -r '.backup' <<<"$INFO")
S3_LS=$(aws "${AWS_FLAGS[@]}" s3 ls "s3://${BUCKET}/" --recursive 2>&1 || true)
if [ -z "$S3_LS" ]; then
  echo "(bucket ${BUCKET} empty or first-run)"
else
  echo "$S3_LS" | head -20
fi

echo
echo "=== 7. EventBridge rules ==="
aws "${AWS_FLAGS[@]}" events list-rules \
  --name-prefix "${NAME_PREFIX}" \
  --query 'Rules[].{Name:Name,Schedule:ScheduleExpression,State:State}' --output table

echo
echo "All smoke checks done."
