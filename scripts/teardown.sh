#!/bin/bash
#
# Safe teardown of a zeelool-ck cluster. Walks the operator through the
# hardened-by-design steps required to destroy the stack:
#
#   1. Confirm intent (type the cluster name).
#   2. Empty the backup bucket (Terraform can't destroy a non-empty versioned bucket).
#   3. Patch modules/clickhouse-node/main.tf to drop `lifecycle { prevent_destroy = true }`.
#   4. terraform apply (applies the lifecycle removal).
#   5. terraform destroy.
#   6. Restore the prevent_destroy block so the repo is left in a safe default state.
#
# This exists because `prevent_destroy` in Terraform must be a literal true/false —
# it can't be a variable. So the only clean way to destroy guarded resources is
# to edit the lifecycle block and re-apply. This script does that transactionally.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
cd terraform/envs/prod

INFO=$(terraform output -json cluster_info 2>/dev/null || echo '{}')
NAME_PREFIX=$(jq -r '.name_prefix // "<unknown>"' <<<"$INFO")
REGION=$(jq -r '.region // "<unknown>"' <<<"$INFO")
BUCKET=$(jq -r '.backup // "<unknown>"' <<<"$INFO")

AWS_FLAGS=(--region "$REGION")
if [ -n "${AWS_PROFILE:-}" ]; then AWS_FLAGS+=(--profile "$AWS_PROFILE"); fi

cat <<EOF
═══════════════════════════════════════════════════════════════════════════
⚠  DESTRUCTIVE — this will destroy the entire ClickHouse cluster.

    Target cluster : $NAME_PREFIX
    Region         : $REGION
    Backup bucket  : $BUCKET  (all backup objects will be deleted!)

    Data loss is permanent. Confirm by typing the cluster name below.
═══════════════════════════════════════════════════════════════════════════
EOF

read -rp "Type '$NAME_PREFIX' to continue: " CONFIRM
if [ "$CONFIRM" != "$NAME_PREFIX" ]; then
  echo "aborted — input did not match cluster name."
  exit 1
fi

# -------- Step 2: empty the backup bucket (versioned + lifecycle means versions too) --------

echo
echo "--- Step 2/5: emptying s3://$BUCKET ---"
if aws "${AWS_FLAGS[@]}" s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws "${AWS_FLAGS[@]}" s3 rm "s3://$BUCKET/" --recursive || true

  # Also purge all versions + delete markers (required before bucket destroy)
  VERSIONS=$(aws "${AWS_FLAGS[@]}" s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{"Objects":null}')
  MARKERS=$(aws "${AWS_FLAGS[@]}" s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{"Objects":null}')
  if [ "$(jq '.Objects | length // 0' <<<"$VERSIONS")" -gt 0 ]; then
    aws "${AWS_FLAGS[@]}" s3api delete-objects --bucket "$BUCKET" --delete "$VERSIONS" >/dev/null || true
  fi
  if [ "$(jq '.Objects | length // 0' <<<"$MARKERS")" -gt 0 ]; then
    aws "${AWS_FLAGS[@]}" s3api delete-objects --bucket "$BUCKET" --delete "$MARKERS" >/dev/null || true
  fi
else
  echo "  (bucket doesn't exist or already gone)"
fi

# -------- Step 3: temporarily remove prevent_destroy --------

CK_MAIN="$REPO_ROOT/terraform/modules/clickhouse-node/main.tf"
BACKUP_FILE="${CK_MAIN}.teardown-backup.$$"

echo
echo "--- Step 3/5: patching $CK_MAIN to drop prevent_destroy ---"
cp "$CK_MAIN" "$BACKUP_FILE"

# Remove the entire lifecycle block that contains prevent_destroy on aws_ebs_volume.data.
# We match the block by finding the lifecycle lines between the comment and the closing brace.
python3 - "$CK_MAIN" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
# Drop the multi-line lifecycle block inside aws_ebs_volume.data that has prevent_destroy = true.
pattern = re.compile(
    r'\n  # Guard.*?terraform destroy.*?\n  lifecycle \{\n    prevent_destroy = true\n  \}\n',
    re.DOTALL,
)
new = pattern.sub('\n', src)
if new == src:
    print("WARN: prevent_destroy lifecycle block not found — maybe already patched.", file=sys.stderr)
open(path, 'w').write(new)
PY

# -------- Step 4: apply (so Terraform records the lifecycle removal) --------

echo
echo "--- Step 4/5: terraform apply (lifecycle update) ---"
terraform apply -auto-approve

# -------- Step 5: destroy --------

echo
echo "--- Step 5/5: terraform destroy ---"
terraform destroy -auto-approve

# -------- Restore --------

echo
echo "--- Restoring $CK_MAIN to its safe default (prevent_destroy = true) ---"
mv "$BACKUP_FILE" "$CK_MAIN"

echo
echo "Teardown complete. Next deploy will again guard data volumes by default."
