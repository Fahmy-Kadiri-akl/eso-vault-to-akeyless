#!/bin/bash
# Mirror Vault KV v2 secrets to Akeyless static secrets.
#
# Both Vault and Akeyless store grouped key/value pairs per path:
#   Vault:    secret/data/demo-app/database -> { host, port, username, ... }
#   Akeyless: /demo-app/database            -> '{"host":"...","port":"...",...}'
#
# This script reads each Vault KV path and creates an Akeyless static
# secret with the same data encoded as JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

: "${VAULT_ADDR:?Set VAULT_ADDR}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN}"
: "${AKEYLESS_TOKEN:?Set AKEYLESS_TOKEN (run: akeyless auth or use the API)}"

AKEYLESS_API="${AKEYLESS_API:-https://api.akeyless.io}"

# Vault paths to migrate (add your paths here)
VAULT_PATHS=(
  "demo-app/database"
  "demo-app/api-keys"
  "demo-app/config"
)

CREATED=0
FAILED=0

for vault_path in "${VAULT_PATHS[@]}"; do
  akl_path="/${vault_path}"
  echo -n "Migrating: secret/data/$vault_path -> $akl_path ... "

  # Read the Vault KV entry and extract the data object as JSON
  JSON_VALUE=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/secret/data/$vault_path" \
    | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['data']['data']))")

  if [ -z "$JSON_VALUE" ]; then
    echo "FAILED (could not read from Vault)"
    ((FAILED++))
    continue
  fi

  # Create Akeyless static secret with the JSON value
  RESP=$(curl -s -X POST "$AKEYLESS_API/create-secret" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json, sys
print(json.dumps({
    'token': sys.argv[1],
    'name': sys.argv[2],
    'value': sys.argv[3]
}))
" "$AKEYLESS_TOKEN" "$akl_path" "$JSON_VALUE")" 2>/dev/null)

  if echo "$RESP" | python3 -c "import sys,json; json.load(sys.stdin)['name']" > /dev/null 2>&1; then
    echo "ok"
    ((CREATED++))
  else
    ERR=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown'))" 2>/dev/null || echo "$RESP")
    echo "FAILED: $ERR"
    ((FAILED++))
  fi
done

echo ""
echo "Done. Created: $CREATED, Failed: $FAILED"
