#!/bin/bash
# Remove Vault ESO resources after successful migration.
# Run only after validating all secrets sync from Akeyless.
set -euo pipefail

NAMESPACE="${1:-demo}"

echo "Removing Vault ExternalSecrets from namespace: $NAMESPACE"
kubectl get externalsecrets -n "$NAMESPACE" -l '!migration-source' -o name | while read es; do
  echo "  Deleting $es"
  kubectl delete "$es" -n "$NAMESPACE"
done

echo ""
echo "Removing Vault ClusterSecretStore..."
kubectl delete clustersecretstore vault 2>/dev/null || echo "  (not found)"

echo ""
echo "Removing Vault ESO service account and token..."
kubectl delete secret vault-eso-auth-token -n external-secrets 2>/dev/null || true
kubectl delete sa vault-eso-auth -n external-secrets 2>/dev/null || true

echo ""
echo "Remaining ClusterSecretStores:"
kubectl get clustersecretstores
echo ""
echo "ExternalSecrets in $NAMESPACE:"
kubectl get externalsecrets -n "$NAMESPACE"
