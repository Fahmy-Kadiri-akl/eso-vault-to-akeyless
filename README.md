# ESO Migration: Vault to Akeyless

Migrate External Secrets Operator (ESO) from HashiCorp Vault to Akeyless with zero application downtime. The app deployment YAML never changes -- only the ExternalSecret and ClusterSecretStore CRs are modified.

## Architecture

```
BEFORE                              AFTER
------                              -----
App Pod                             App Pod
  |                                   |
  v                                   v
K8s Secret                          K8s Secret
(same name, same keys)              (same name, same keys)
  ^                                   ^
  |                                   |
ExternalSecret                      ExternalSecret
  |                                   |
  v                                   v
ClusterSecretStore (vault)          ClusterSecretStore (akeyless)
  |                                   |
  v                                   v
Vault KV v2                         Akeyless Gateway
```

## Prerequisites

- Kubernetes cluster with ESO already installed
- Vault running and accessible from the cluster (current state)
- Akeyless Gateway deployed and accessible from the cluster
- Akeyless auth method configured (GCP, AWS IAM, Azure AD, or API key)
- `kubectl` access to the cluster

### Install ESO (if not already present)

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --set installCRDs=true --wait
```

## Secret Path Mapping

The biggest structural difference between Vault and Akeyless is how secrets are addressed:

| Vault KV v2 | Akeyless |
|---|---|
| Path: `demo-app/database`, Property: `host` | Path: `/demo-app/database/host` |
| Path: `demo-app/database`, Property: `port` | Path: `/demo-app/database/port` |
| Multiple keys per path | One value per path |

This means every Vault `remoteRef` with a `property` field becomes a separate Akeyless `remoteRef` with the property appended to the key path.

**Vault ExternalSecret:**
```yaml
- secretKey: host
  remoteRef:
    key: demo-app/database      # Vault KV path
    property: host               # Key within the KV entry
```

**Akeyless ExternalSecret:**
```yaml
- secretKey: host
  remoteRef:
    key: /demo-app/database/host  # Full path, no property field
```

## Migration Steps

### Step 1: Set up Vault ESO (current state)

```bash
# Create service account for Vault K8s auth
kubectl apply -f manifests/01-vault-setup/vault-eso-serviceaccount.yaml

# Configure Vault K8s auth, policy, and role
export VAULT_ADDR=http://vault.vault.svc.cluster.local:8200
export VAULT_TOKEN=<your-token>
bash manifests/01-vault-setup/vault-k8s-auth.sh

# Create Vault ClusterSecretStore
kubectl apply -f manifests/02-eso-vault/clustersecretstore-vault.yaml

# Create ExternalSecrets and demo app
kubectl apply -f manifests/02-eso-vault/externalsecrets-vault.yaml
kubectl apply -f manifests/02-eso-vault/demo-app.yaml

# Verify
kubectl get externalsecrets -n demo    # All should show SecretSynced
kubectl exec -n demo deploy/demo-app -- env | grep DB_HOST
```

### Step 2: Mirror secrets to Akeyless

Copy every Vault secret to Akeyless. Use the provided script or do it manually:

```bash
export VAULT_ADDR=http://vault:8200
export VAULT_TOKEN=<token>
export AKEYLESS_TOKEN=$(akeyless auth --access-id p-xxx --access-type gcp -o json | jq -r .token)
bash scripts/mirror-secrets-to-akeyless.sh
```

### Step 3: Add Akeyless ClusterSecretStore (alongside Vault)

```bash
# Create auth secret (edit with your access-id first)
kubectl apply -f manifests/03-eso-akeyless/akeyless-auth-secret.yaml

# Create Akeyless ClusterSecretStore (edit gateway URL first)
kubectl apply -f manifests/03-eso-akeyless/clustersecretstore-akeyless.yaml

# Verify both stores are Ready
kubectl get clustersecretstores
# NAME       STATUS   READY
# vault      Valid    True
# akeyless   Valid    True
```

### Step 4: Deploy parallel Akeyless ExternalSecrets

This creates temporary `-akl` suffixed K8s secrets for validation. The existing Vault-backed secrets remain untouched.

```bash
kubectl apply -f manifests/04-migration/externalsecrets-akeyless-parallel.yaml

# Wait for sync
kubectl get externalsecrets -n demo
# Both vault and akeyless ExternalSecrets should show SecretSynced
```

### Step 5: Validate

Compare every Vault-backed secret against its Akeyless counterpart:

```bash
bash scripts/validate-migration.sh demo

# Output:
# Comparing: database-credentials vs database-credentials-akl
#   MATCH
# Comparing: api-keys vs api-keys-akl
#   MATCH
# Comparing: app-config vs app-config-akl
#   MATCH
# Results: 3 passed, 0 failed
```

### Step 6: Cut over

Remove Vault ExternalSecrets (this deletes the Vault-backed K8s secrets), then update the Akeyless ExternalSecrets to target the original secret names:

```bash
# Delete Vault ExternalSecrets
kubectl delete externalsecret demo-database demo-api-keys demo-config -n demo

# Update Akeyless ExternalSecrets to use original secret names
kubectl apply -f manifests/04-migration/externalsecrets-akeyless-final.yaml

# The app deployment does NOT need to change.
# Same secret names, same keys, new source.
kubectl rollout restart deployment/demo-app -n demo
kubectl exec -n demo deploy/demo-app -- env | grep DB_HOST
```

### Step 7: Cleanup

```bash
bash manifests/05-cleanup/remove-vault.sh demo

# This removes:
# - Vault ClusterSecretStore
# - vault-eso-auth ServiceAccount and token
```

## Rollback

At any point before Step 6, rollback is trivial:

```bash
# Remove Akeyless ExternalSecrets (temporary -akl secrets get deleted)
kubectl delete externalsecret -n demo -l migration-source=akeyless

# Remove Akeyless ClusterSecretStore
kubectl delete clustersecretstore akeyless
kubectl delete secret akeyless-auth -n external-secrets

# Vault ExternalSecrets are still running, app is unaffected.
```

After Step 6, to roll back:

```bash
# Re-create Vault ClusterSecretStore
kubectl apply -f manifests/02-eso-vault/clustersecretstore-vault.yaml

# Re-create Vault ExternalSecrets (they will recreate the K8s secrets)
kubectl apply -f manifests/02-eso-vault/externalsecrets-vault.yaml

# Delete Akeyless ExternalSecrets
kubectl delete externalsecret -n demo -l migration-source=akeyless

# Restart app to pick up Vault-backed secrets
kubectl rollout restart deployment/demo-app -n demo
```

## Namespace-by-Namespace vs Cluster-Wide

This repo demonstrates namespace-by-namespace migration, which is the recommended approach:

1. Both ClusterSecretStores (Vault + Akeyless) exist cluster-wide
2. Each namespace is migrated independently
3. Some namespaces can run on Vault while others run on Akeyless
4. Rollback scope is per-namespace, not cluster-wide

For cluster-wide cutover, apply all the `04-migration` manifests across all namespaces at once, validate, then remove all Vault ExternalSecrets.

## Errors Encountered During Migration

### 1. ESO API version mismatch

**Error:**
```
error: resource mapping not found for name: "vault" namespace: ""
from "STDIN": no matches for kind "ClusterSecretStore" in version "external-secrets.io/v1beta1"
```

**Cause:** ESO v0.12+ uses `external-secrets.io/v1` instead of `v1beta1`. Many online examples still show the old version.

**Fix:** Check your ESO version and use the correct API version:
```bash
kubectl api-resources | grep externalsecret
```

### 2. Vault Kubernetes auth needs a long-lived SA token

**Error:** ESO ClusterSecretStore shows `SecretRef` error or Vault returns 403.

**Cause:** Kubernetes 1.24+ no longer auto-creates long-lived tokens for service accounts. ESO needs a persistent token to authenticate to Vault.

**Fix:** Explicitly create a `kubernetes.io/service-account-token` Secret:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-eso-auth-token
  annotations:
    kubernetes.io/service-account.name: vault-eso-auth
type: kubernetes.io/service-account-token
```

### 3. Vault KV v2 property vs Akeyless flat paths

**Error:** ExternalSecret shows `SecretSynced` but K8s secret values are wrong or contain JSON.

**Cause:** Vault KV v2 stores multiple keys per path. If you omit `property`, ESO returns the entire JSON object. Akeyless stores one value per path, so there is no `property` field.

**Fix:** Map each Vault `key + property` pair to a single Akeyless `key`:
- Vault: `key: demo-app/database`, `property: host`
- Akeyless: `key: /demo-app/database/host`

### 4. GCP metadata service access from pods

**Error:** Akeyless ClusterSecretStore fails to validate with GCP auth.

**Cause:** On non-GKE clusters (e.g. microk8s on a GCP VM), pods may not be able to reach the GCP metadata service at `169.254.169.254`.

**Fix:** Verify pod-level metadata access first:
```bash
kubectl run test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email" \
  -H "Metadata-Flavor: Google"
```
If this fails, the cluster network doesn't route metadata traffic. On microk8s, enabling the `host-access` addon or using `--network host` can help. On GKE, this works out of the box.

### 5. Akeyless ClusterSecretStore shows ReadOnly

**Symptom:** `kubectl get clustersecretstore akeyless` shows `Capabilities: ReadOnly` instead of `ReadWrite`.

**Cause:** This is expected. The Akeyless ESO provider only supports read operations by default. Push secrets to Akeyless via the API or CLI, not through ESO.

### 6. ExternalSecret owner references and secret deletion

**Symptom:** Deleting a Vault ExternalSecret also deletes the K8s Secret it created.

**Cause:** `creationPolicy: Owner` (default) sets an `ownerReference` on the K8s Secret. When the ExternalSecret is deleted, the Secret is garbage collected.

**Impact:** This is actually the desired behavior during migration. The Akeyless ExternalSecret recreates the Secret with the same name. But be aware: there is a brief window where the Secret does not exist. If a pod restarts during this window, it will fail to mount the secret.

**Mitigation:** During cutover (Step 6), first apply the Akeyless final ExternalSecrets that target the original names, wait for sync, THEN delete the Vault ExternalSecrets. Or use `creationPolicy: Merge` to avoid deletion.

## Tested Environment

- Kubernetes: microk8s v1.33 on GCP VM (Ubuntu 24.04)
- ESO: external-secrets (Helm, latest)
- Vault: 1.21.2 (dev mode, KV v2)
- Akeyless Gateway: 4.48.0
- Akeyless auth: GCP workload identity
- All manifests use `external-secrets.io/v1` API
