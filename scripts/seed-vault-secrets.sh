#!/bin/bash
# Seed Vault KV v2 with demo application secrets.
set -euo pipefail

: "${VAULT_ADDR:?Set VAULT_ADDR}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN}"

echo "Seeding Vault secrets..."

curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/demo-app/database" \
  -d '{"data": {"host": "postgres.demo.svc.cluster.local", "port": "5432", "username": "demo_user", "password": "S3cureP@ss2026!", "database": "demo_db"}}' > /dev/null
echo "  demo-app/database"

curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/demo-app/api-keys" \
  -d '{"data": {"stripe_key": "sk_test_abc123", "sendgrid_key": "SG.xyz789", "datadog_api_key": "dd-api-key-456"}}' > /dev/null
echo "  demo-app/api-keys"

curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/demo-app/config" \
  -d '{"data": {"app_env": "production", "log_level": "info", "feature_flags": "enable_v2_api,dark_mode"}}' > /dev/null
echo "  demo-app/config"

echo "Done. 3 secret groups (11 total keys) created."
