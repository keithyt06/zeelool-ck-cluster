#!/bin/bash
#
# Render ClickHouse configs from .tftpl templates + a secret password, then
# push them to every CK node via the render-clickhouse-config SSM Document.
#
# All cluster topology (region, IPs, instance IDs, SSM doc names, cluster_name,
# VPC CIDR for user ACL) is read from `terraform output -json cluster_info`,
# so this script works against any customer deployment without edits.
#
# Password source: SSM Parameter Store SecureString at
#   /<name_prefix>/default-user-password
#
# First run (bootstrap — once per cluster):
#   PASS=$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)
#   aws ssm put-parameter \
#     --name /<name_prefix>/default-user-password \
#     --type SecureString --value "$PASS" \
#     --region <region>
#
# Re-run this script whenever a template or the password changes.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
cd terraform/envs/prod

# -------- Pull topology from terraform outputs --------

# Strip trailing deprecation warnings that terraform emits after the JSON
# payload on stdout — keep only the balanced top-level {...} object.
INFO=$(terraform output -no-color -json cluster_info 2>/dev/null \
  | sed '/^$/,$d')
REGION=$(jq -r '.region' <<<"$INFO")
NAME_PREFIX=$(jq -r '.name_prefix' <<<"$INFO")
CLUSTER_NAME=$(jq -r '.cluster_name' <<<"$INFO")
VPC_ID=$(jq -r '.vpc_id' <<<"$INFO")
RENDER_DOC=$(jq -r '.ssm_docs.render_clickhouse_config' <<<"$INFO")

AWS_FLAGS=(--region "$REGION")
if [ -n "${AWS_PROFILE:-}" ]; then AWS_FLAGS+=(--profile "$AWS_PROFILE"); fi

# VPC CIDR — used in users.d/default-user.xml <networks> ACL.
VPC_CIDR=$(aws "${AWS_FLAGS[@]}" ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' --output text)

# -------- 1. Fetch password from SSM, compute SHA256 hex --------

PASS_PARAM="/${NAME_PREFIX}/default-user-password"
PASS=$(aws "${AWS_FLAGS[@]}" ssm get-parameter \
  --name "$PASS_PARAM" --with-decryption \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")

if [ -z "$PASS" ] || [ "$PASS" = "None" ]; then
  cat >&2 <<EOF
ERROR: password parameter $PASS_PARAM not set.

Bootstrap once with:
  PASS=\$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)
  aws --region $REGION ssm put-parameter \\
    --name "$PASS_PARAM" --type SecureString --value "\$PASS" \\
    --description "ClickHouse default user password"
  # then save \$PASS to your password manager.
EOF
  exit 1
fi
PASS_SHA=$(printf '%s' "$PASS" | sha256sum | awk '{print $1}')

# -------- 2. Render templates to /tmp --------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# users.d/default-user.xml — password + network ACL (all VPC IPs + loopback)
sed -e "s|\${default_password_sha256}|${PASS_SHA}|g" \
    -e "s|<ip>10.0.0.0/16</ip>|<ip>${VPC_CIDR}</ip>|g" \
  "$REPO_ROOT/config/clickhouse/users.d/default-user.xml.tftpl" \
  > "$TMP/default-user.xml"

# remote-servers.xml — enumerate every CK replica from terraform
CK_REPLICAS=$(jq -r '.clickhouses | to_entries | map(
  "                <replica><host>\(.value.private_ip)</host><port>9000</port></replica>"
) | join("\n")' <<<"$INFO")

cat > "$TMP/remote-servers.xml" <<EOF
<clickhouse>
    <remote_servers>
        <${CLUSTER_NAME}>
            <shard>
                <internal_replication>true</internal_replication>
${CK_REPLICAS}
            </shard>
        </${CLUSTER_NAME}>
    </remote_servers>
</clickhouse>
EOF

# zookeeper.xml — all Keeper endpoints
KEEPER_NODES=$(jq -r '.keepers | to_entries | map(
  "        <node><host>\(.value.private_ip)</host><port>9181</port></node>"
) | join("\n")' <<<"$INFO")

cat > "$TMP/zookeeper.xml" <<EOF
<clickhouse>
    <zookeeper>
${KEEPER_NODES}
        <session_timeout_ms>30000</session_timeout_ms>
        <operation_timeout_ms>10000</operation_timeout_ms>
    </zookeeper>
</clickhouse>
EOF

# -------- 3. Per-node macros.xml + interserver.xml --------

for name in $(jq -r '.clickhouses | keys[]' <<<"$INFO"); do
  ip=$(jq -r --arg n "$name" '.clickhouses[$n].private_ip' <<<"$INFO")
  sed -e "s|\${cluster_name}|${CLUSTER_NAME}|g" \
      -e "s|\${shard}|01|g" \
      -e "s|\${replica}|${name}|g" \
    "$REPO_ROOT/config/clickhouse/config.d/macros.xml.tftpl" \
    > "$TMP/macros-${name}.xml"
  sed -e "s|\${private_ip}|${ip}|g" \
    "$REPO_ROOT/config/clickhouse/config.d/interserver.xml.tftpl" \
    > "$TMP/interserver-${name}.xml"
done

# -------- 4. Base64 + push via SSM --------

RS_B64=$(base64 -w0 "$TMP/remote-servers.xml")
ZK_B64=$(base64 -w0 "$TMP/zookeeper.xml")
USERS_B64=$(base64 -w0 "$TMP/default-user.xml")
LISTEN_B64=$(base64 -w0 "$REPO_ROOT/config/clickhouse/config.d/listen.xml")

for name in $(jq -r '.clickhouses | keys[]' <<<"$INFO"); do
  iid=$(jq -r --arg n "$name" '.clickhouses[$n].instance_id' <<<"$INFO")
  macros_b64=$(base64 -w0 "$TMP/macros-${name}.xml")
  inter_b64=$(base64 -w0 "$TMP/interserver-${name}.xml")

  cmd=$(aws "${AWS_FLAGS[@]}" ssm send-command \
    --document-name "$RENDER_DOC" \
    --instance-ids "$iid" \
    --parameters "RemoteServersXml=${RS_B64},ZookeeperXml=${ZK_B64},MacrosXml=${macros_b64},InterserverXml=${inter_b64},ListenXml=${LISTEN_B64},UsersXml=${USERS_B64}" \
    --query 'Command.CommandId' --output text)
  echo "$name ($iid) → cmd=$cmd"

  aws "${AWS_FLAGS[@]}" ssm wait command-executed \
    --command-id "$cmd" --instance-id "$iid"
  status=$(aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
    --command-id "$cmd" --instance-id "$iid" \
    --query 'Status' --output text)
  echo "  → $status"
  if [ "$status" != "Success" ]; then
    aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
      --command-id "$cmd" --instance-id "$iid" \
      --query 'StandardErrorContent' --output text >&2
    exit 1
  fi
done

FQDN=$(jq -r '.fqdn' <<<"$INFO")
echo
echo "Done. Verify:"
echo "  clickhouse-client --host $FQDN --user default --password '<pass>' --query 'SELECT 1'"
echo "  (empty password should fail — confirms auth is active)"
