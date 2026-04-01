#!/bin/bash
# Seed Vault KV v2 with demo application secrets.
# Values are read from .env -- see .env.example for the template.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

: "${VAULT_ADDR:?Set VAULT_ADDR}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN}"
: "${DB_HOST:?Set DB_HOST in .env}"
: "${DB_PORT:?Set DB_PORT in .env}"
: "${DB_USERNAME:?Set DB_USERNAME in .env}"
: "${DB_PASSWORD:?Set DB_PASSWORD in .env}"
: "${DB_NAME:?Set DB_NAME in .env}"
: "${STRIPE_KEY:?Set STRIPE_KEY in .env}"
: "${SENDGRID_KEY:?Set SENDGRID_KEY in .env}"
: "${DATADOG_API_KEY:?Set DATADOG_API_KEY in .env}"
: "${APP_ENV:?Set APP_ENV in .env}"
: "${LOG_LEVEL:?Set LOG_LEVEL in .env}"
: "${FEATURE_FLAGS:?Set FEATURE_FLAGS in .env}"

echo "Seeding Vault secrets..."

curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/demo-app/database" \
  -d "$(jq -n \
    --arg host "$DB_HOST" --arg port "$DB_PORT" \
    --arg user "$DB_USERNAME" --arg pass "$DB_PASSWORD" --arg db "$DB_NAME" \
    '{data: {host: $host, port: $port, username: $user, password: $pass, database: $db}}')" > /dev/null
echo "  demo-app/database"

curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/demo-app/api-keys" \
  -d "$(jq -n \
    --arg stripe "$STRIPE_KEY" --arg sg "$SENDGRID_KEY" --arg dd "$DATADOG_API_KEY" \
    '{data: {stripe_key: $stripe, sendgrid_key: $sg, datadog_api_key: $dd}}')" > /dev/null
echo "  demo-app/api-keys"

curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/demo-app/config" \
  -d "$(jq -n \
    --arg env "$APP_ENV" --arg log "$LOG_LEVEL" --arg flags "$FEATURE_FLAGS" \
    '{data: {app_env: $env, log_level: $log, feature_flags: $flags}}')" > /dev/null
echo "  demo-app/config"

echo "Done. 3 secret groups (11 total keys) created."
