#!/bin/bash
# Configure Vault Kubernetes auth, policy, and role for ESO
# Run this from a machine that can reach Vault.
set -euo pipefail

: "${VAULT_ADDR:?Set VAULT_ADDR}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN}"

echo "Enabling Kubernetes auth..."
curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/sys/auth/kubernetes" \
  -d '{"type":"kubernetes"}' 2>/dev/null || echo "(already enabled)"

echo "Configuring Kubernetes auth..."
K8S_HOST="${K8S_HOST:-https://kubernetes.default.svc:443}"
curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/auth/kubernetes/config" \
  -d "{\"kubernetes_host\": \"$K8S_HOST\", \"disable_local_ca_jwt\": false}"

echo "Creating ESO reader policy..."
curl -sf -X PUT -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/sys/policies/acl/eso-reader" \
  -d '{"policy": "path \"secret/data/*\" { capabilities = [\"read\"] }\npath \"secret/metadata/*\" { capabilities = [\"read\", \"list\"] }"}'

echo "Creating ESO role..."
curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/auth/kubernetes/role/eso-role" \
  -d "{\"bound_service_account_names\": [\"vault-eso-auth\"], \"bound_service_account_namespaces\": [\"external-secrets\"], \"policies\": [\"eso-reader\"], \"ttl\": \"1h\"}"

echo "Done. Vault K8s auth ready for ESO."
