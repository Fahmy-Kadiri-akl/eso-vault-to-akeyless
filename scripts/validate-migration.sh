#!/bin/bash
# Validate that Akeyless-backed K8s secrets match the Vault-backed originals.
# Run this during the parallel phase (step 2) before cutting over.
set -euo pipefail

NAMESPACE="${1:-demo}"
KUBECTL="${KUBECTL:-kubectl}"

# Pairs: vault-secret-name akeyless-secret-name
PAIRS=(
  "database-credentials database-credentials-akl"
  "api-keys api-keys-akl"
  "app-config app-config-akl"
)

PASS=0
FAIL=0

decode_secret() {
  $KUBECTL get secret "$1" -n "$NAMESPACE" -o json 2>/dev/null | \
    python3 -c "
import sys, json, base64
data = json.load(sys.stdin).get('data', {})
for k in sorted(data):
    print(f'{k}={base64.b64decode(data[k]).decode()}')
" 2>/dev/null
}

for pair in "${PAIRS[@]}"; do
  read -r vault_name akl_name <<< "$pair"
  echo "Comparing: $vault_name vs $akl_name"

  VAULT_DATA=$(decode_secret "$vault_name")
  AKL_DATA=$(decode_secret "$akl_name")

  if [ -z "$VAULT_DATA" ]; then
    echo "  WARNING: $vault_name not found"
    ((FAIL++))
    continue
  fi

  if [ -z "$AKL_DATA" ]; then
    echo "  WARNING: $akl_name not found"
    ((FAIL++))
    continue
  fi

  if [ "$VAULT_DATA" = "$AKL_DATA" ]; then
    echo "  MATCH"
    ((PASS++))
  else
    echo "  MISMATCH"
    diff <(echo "$VAULT_DATA") <(echo "$AKL_DATA") || true
    ((FAIL++))
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
