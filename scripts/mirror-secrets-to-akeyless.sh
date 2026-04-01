#!/bin/bash
# Mirror Vault KV v2 secrets to Akeyless static secrets.
#
# Vault KV v2 stores multiple keys per path:
#   secret/data/demo-app/database -> { host, port, username, password, database }
#
# Akeyless stores one value per secret path:
#   /demo-app/database/host -> "postgres.demo.svc.cluster.local"
#
# This script reads from Vault and creates the equivalent Akeyless secrets.
# Values are read from .env -- see .env.example for the template.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

: "${VAULT_ADDR:?Set VAULT_ADDR}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN}"
: "${AKEYLESS_TOKEN:?Set AKEYLESS_TOKEN (run: akeyless auth or use the API)}"

AKEYLESS_API="${AKEYLESS_API:-https://api.akeyless.io}"
PREFIX="${AKEYLESS_PREFIX:-/demo-app}"  # Akeyless path prefix

# Vault paths to migrate
VAULT_PATHS=(
  "demo-app/database"
  "demo-app/api-keys"
  "demo-app/config"
)

CREATED=0
FAILED=0

for vault_path in "${VAULT_PATHS[@]}"; do
  echo "Reading Vault: secret/data/$vault_path"
  VAULT_DATA=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/secret/data/$vault_path" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['data']
for k, v in data.items():
    print(f'{k}\t{v}')
")

  while IFS=$'\t' read -r key value; do
    akl_path="/${vault_path}/${key}"
    echo -n "  Creating $akl_path... "
    RESP=$(curl -s -X POST "$AKEYLESS_API/create-secret" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "import json; print(json.dumps({'token': '$AKEYLESS_TOKEN', 'name': '$akl_path', 'value': '$value'}))")" 2>/dev/null)

    if echo "$RESP" | python3 -c "import sys,json; json.load(sys.stdin)['name']" > /dev/null 2>&1; then
      echo "ok"
      ((CREATED++))
    else
      ERR=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown error'))" 2>/dev/null || echo "$RESP")
      echo "FAILED: $ERR"
      ((FAILED++))
    fi
  done <<< "$VAULT_DATA"
done

echo ""
echo "Done. Created: $CREATED, Failed: $FAILED"
