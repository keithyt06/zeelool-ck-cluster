#!/bin/bash
#
# Install or rotate a public SSH key on every Keeper + CK node via SSM.
# Appends to /home/ec2-user/.ssh/authorized_keys. Idempotent — rerun freely
# to add a second operator's key or to push the same key after expanding
# the cluster.
#
# Use cases:
#   - Cluster was deployed without ssh_key_name in tfvars — add SSH access now.
#   - Onboard a new operator's public key alongside existing ones.
#   - Rotate keys: push new key, confirm it works, then manually remove old
#     lines from authorized_keys.
#
# Required arg: path to a PEM private key OR a .pub public key.
#   PEM → public key is derived via `ssh-keygen -y` (never leaves this process)
#   .pub → read directly
#
# PEM path is ALWAYS an explicit CLI arg — never hardcoded in this repo.
# Customers / operators pass their own path at invocation time.
#
# Usage:
#   scripts/install-ssh-public-key.sh ~/.ssh/my-keypair.pem
#   scripts/install-ssh-public-key.sh /path/to/ops-team.pub
#
# Optional env:
#   AWS_PROFILE         passed through to aws
#   TARGET_INSTANCE_IDS space-separated list of instance IDs to target
#                       (default: every CK + Keeper from terraform outputs)

set -euo pipefail

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 <path-to-private-pem-or-public-key>" >&2
  exit 1
fi

KEY_FILE="$1"

# -------- Derive public key (works for both PEM and .pub) --------
case "$KEY_FILE" in
  *.pub)
    PUBKEY=$(cat "$KEY_FILE")
    ;;
  *)
    # Treat as private key; extract public half.
    PUBKEY=$(ssh-keygen -y -f "$KEY_FILE" 2>/dev/null) || {
      echo "ERROR: $KEY_FILE is neither a valid PEM nor *.pub public key" >&2
      exit 1
    }
    ;;
esac

# Strip any accidental CR/whitespace and tag the line with source filename so
# operators can spot which key came from where.
PUBKEY=$(printf '%s' "$PUBKEY" | tr -d '\r' | awk '{$1=$1; print}')
KEY_TAG="$(basename "$KEY_FILE" | sed 's/[^A-Za-z0-9._-]/_/g')"
PUBKEY_LINE="${PUBKEY} ck-ssm-${KEY_TAG}-$(date -u +%Y%m%d)"

# -------- Pull topology from terraform --------
cd "$(dirname "$0")/../terraform/envs/prod"

# Terraform may append deprecation warnings to stdout AFTER the JSON blob.
# Keep only lines from the first `{` up to (and including) the first `}` at
# column 1 — that's the top-level closing brace of a pretty-printed JSON object.
ALL=$(terraform output -no-color -json 2>/dev/null \
  | sed '/^$/,$d')

# Prefer the unified cluster_info output; fall back to the individual
# pre-refactor outputs so this script works against older state that hasn't
# been applied since the refactor.
INFO=$(jq -c '.cluster_info.value // empty' <<<"$ALL")
if [ -n "$INFO" ]; then
  REGION=$(jq -r '.region' <<<"$INFO")
  IDS_COMBINED=$(jq -c '(.clickhouses + .keepers) | to_entries | map(.value.instance_id)' <<<"$INFO")
else
  REGION=$(jq -r '.region.value // empty' <<<"$ALL")
  if [ -z "$REGION" ]; then
    REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
    echo "(terraform state has no region output; assuming $REGION — override via AWS_REGION env)" >&2
  fi
  IDS_COMBINED=$(jq -c '
    ((.clickhouse_instance_ids.value // {}) + (.keeper_instance_ids.value // {}))
    | to_entries | map(.value)' <<<"$ALL")
fi

AWS_FLAGS=(--region "$REGION")
if [ -n "${AWS_PROFILE:-}" ]; then AWS_FLAGS+=(--profile "$AWS_PROFILE"); fi

if [ -n "${TARGET_INSTANCE_IDS:-}" ]; then
  # shellcheck disable=SC2206
  TARGETS=(${TARGET_INSTANCE_IDS})
else
  mapfile -t TARGETS < <(jq -r '.[]' <<<"$IDS_COMBINED")
fi

echo "Installing public key on ${#TARGETS[@]} instances in $REGION:"
printf '  %s\n' "${TARGETS[@]}"
echo "Key line: ${PUBKEY_LINE:0:60}..."
echo

# -------- Shell snippet that runs on each node --------
# Idempotent: grep the exact key material first, append only if missing.
# `authorized_keys` is created with mode 600 under a .ssh/ dir with mode 700.
REMOTE_SNIPPET=$(cat <<'SHELL'
set -euo pipefail
USER_HOME=/home/ec2-user
SSH_DIR="$USER_HOME/.ssh"
AUTH="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown ec2-user:ec2-user "$SSH_DIR"
touch "$AUTH"
chmod 600 "$AUTH"
chown ec2-user:ec2-user "$AUTH"
KEY_MATERIAL=$(printf '%s' "$PUBKEY_LINE" | awk '{print $1" "$2}')
if grep -qF "$KEY_MATERIAL" "$AUTH"; then
  echo "already present — no-op"
else
  printf '%s\n' "$PUBKEY_LINE" >> "$AUTH"
  echo "appended"
fi
SHELL
)

# We pass PUBKEY_LINE as an SSM parameter via base64 to avoid shell-quoting
# pitfalls (the public key itself contains '=' and whitespace).
PUBKEY_B64=$(printf '%s' "$PUBKEY_LINE" | base64 -w0)
COMMANDS_JSON=$(jq -nc \
  --arg b64 "$PUBKEY_B64" \
  --arg snippet "$REMOTE_SNIPPET" '
  {
    commands: [
      "PUBKEY_LINE=$(echo " + ($b64 | @sh) + " | base64 -d)",
      $snippet
    ]
  }')

for iid in "${TARGETS[@]}"; do
  cmd=$(aws "${AWS_FLAGS[@]}" ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$iid" \
    --cli-input-json "{\"Parameters\":$COMMANDS_JSON}" \
    --query 'Command.CommandId' --output text)
  aws "${AWS_FLAGS[@]}" ssm wait command-executed \
    --command-id "$cmd" --instance-id "$iid" 2>/dev/null || true
  status=$(aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
    --command-id "$cmd" --instance-id "$iid" \
    --query 'Status' --output text)
  out=$(aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
    --command-id "$cmd" --instance-id "$iid" \
    --query 'StandardOutputContent' --output text | tr -d '\n')
  echo "$iid → $status ($out)"
  if [ "$status" != "Success" ]; then
    aws "${AWS_FLAGS[@]}" ssm get-command-invocation \
      --command-id "$cmd" --instance-id "$iid" \
      --query 'StandardErrorContent' --output text >&2
    exit 1
  fi
done

echo
echo "Done. Test SSH (needs bastion or VPN into the VPC):"
echo "  ssh -i $KEY_FILE ec2-user@<private-ip>"
