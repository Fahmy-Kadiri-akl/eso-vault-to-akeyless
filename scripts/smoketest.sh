#!/bin/bash
# Post-cutover smoke test: verify secrets are mounted and pods are healthy.
# Usage: bash scripts/smoketest.sh [namespace]
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${1:-demo}"
PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "  [PASS] $desc"
    ((PASS++))
  else
    echo "  [FAIL] $desc"
    ((FAIL++))
  fi
}

echo "Smoke test: namespace=$NAMESPACE"
echo "================================"
echo ""

echo "1. ClusterSecretStore health"
for store in $($KUBECTL get clustersecretstores -o jsonpath='{.items[*].metadata.name}'); do
  READY=$($KUBECTL get clustersecretstore "$store" -o jsonpath='{.status.conditions[0].status}')
  check "ClusterSecretStore/$store is Ready" [ "$READY" = "True" ]
done

echo ""
echo "2. ExternalSecret sync status"
for es in $($KUBECTL get externalsecrets -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
  STATUS=$($KUBECTL get externalsecret "$es" -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].reason}')
  check "ExternalSecret/$es synced" [ "$STATUS" = "SecretSynced" ]
done

echo ""
echo "3. K8s secrets exist and have data"
for secret in $($KUBECTL get secrets -n "$NAMESPACE" --field-selector type=Opaque -o jsonpath='{.items[*].metadata.name}'); do
  KEYS=$($KUBECTL get secret "$secret" -n "$NAMESPACE" -o jsonpath='{.data}' | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  check "Secret/$secret has $KEYS keys" [ "$KEYS" -gt 0 ]
done

echo ""
echo "4. Pods are running"
for pod in $($KUBECTL get pods -n "$NAMESPACE" --field-selector status.phase=Running -o jsonpath='{.items[*].metadata.name}'); do
  READY=$($KUBECTL get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  check "Pod/$pod is Ready" [ "$READY" = "True" ]
done

echo ""
echo "5. Secret values accessible from pods"
for deploy in $($KUBECTL get deploy -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
  ENV_COUNT=$($KUBECTL exec -n "$NAMESPACE" "deploy/$deploy" -- env 2>/dev/null | wc -l)
  check "deploy/$deploy env vars loaded ($ENV_COUNT vars)" [ "$ENV_COUNT" -gt 5 ]
done

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
