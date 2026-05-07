#!/bin/bash
#
# Render keeper_config.xml per Keeper node from the .tftpl template, then push
# via the render-keeper-config SSM Document. One-shot — call after every Keeper
# topology change (add/remove Keeper, change IPs).
#
# Reads every value from `terraform output -json cluster_info`:
#   region, name_prefix, render_keeper_config doc name, each keeper's
#   {instance_id, private_ip, server_id}.
#
# Optional env:
#   AWS_PROFILE — passed through to aws

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
cd terraform/envs/prod

# Terraform may append deprecation warnings after JSON on stdout;
# trim to the balanced top-level {...}.
INFO=$(terraform output -no-color -json cluster_info 2>/dev/null \
  | awk '/^{/{p=1} p{print} /^}$/{exit}')

if [ -z "$INFO" ]; then
  echo "ERROR: terraform output cluster_info is empty. Did you run 'terraform apply'?" >&2
  exit 1
fi

REGION=$(jq -r '.region' <<<"$INFO")
RENDER_DOC=$(jq -r '.ssm_docs.render_keeper_config' <<<"$INFO")

AWS_FLAGS=(--region "$REGION")
if [ -n "${AWS_PROFILE:-}" ]; then AWS_FLAGS+=(--profile "$AWS_PROFILE"); fi

# -------- Build the shared <raft_configuration> peer list --------
# Every keeper_config.xml has the SAME peer list; what differs per-node is the
# top-level <server_id>.
PEERS_JSON=$(jq -c '
  .keepers | to_entries | map({id: .value.server_id, ip: .value.private_ip})
' <<<"$INFO")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -------- Render + push per keeper --------
for name in $(jq -r '.keepers | keys[]' <<<"$INFO"); do
  iid=$(jq -r --arg n "$name" '.keepers[$n].instance_id' <<<"$INFO")
  sid=$(jq -r --arg n "$name" '.keepers[$n].server_id'   <<<"$INFO")

  # Generate the <raft_configuration> peer block for this node. Same content
  # for every node, regenerated per-node for clarity (cheap).
  peers_xml=$(jq -r '
    map("            <server>\n                <id>\(.id)</id>\n                <hostname>\(.ip)</hostname>\n                <port>9234</port>\n            </server>")
    | join("\n")' <<<"$PEERS_JSON")

  # Expand the template. Our .tftpl has `${server_id}` and a `%{ for peer in
  # peers ~}` loop. We do it with sed/awk since terraform templatefile isn't
  # available at runtime.
  awk -v sid="$sid" -v peers="$peers_xml" '
    /%\{ for peer in peers ~\}/ { inblock=1; next }
    /%\{ endfor ~\}/            { inblock=0; print peers; next }
    !inblock                    { gsub(/\$\{server_id\}/, sid); print }
  ' "$REPO_ROOT/config/keeper/keeper_config.xml.tftpl" \
    > "$TMP/keeper_config-${name}.xml"

  b64=$(base64 -w0 "$TMP/keeper_config-${name}.xml")
  cmd=$(aws "${AWS_FLAGS[@]}" ssm send-command \
    --document-name "$RENDER_DOC" \
    --instance-ids "$iid" \
    --parameters "ConfigXml=${b64}" \
    --query 'Command.CommandId' --output text)
  echo "$name ($iid, server_id=$sid) → cmd=$cmd"

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

echo
echo "Done. Verify Keeper quorum via scripts/smoke.sh (§3)."
