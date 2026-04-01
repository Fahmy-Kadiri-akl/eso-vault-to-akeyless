#!/bin/bash
# Scan a cluster for all Vault-backed ExternalSecrets and generate
# equivalent Akeyless ExternalSecret YAMLs.
#
# Usage:
#   bash scripts/inventory.sh                    # all namespaces
#   bash scripts/inventory.sh -n demo            # single namespace
#   bash scripts/inventory.sh -s vault           # filter by store name
#   bash scripts/inventory.sh -o manifests/gen   # output directory
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE=""
STORE_NAME="vault"
OUTPUT_DIR=""

while getopts "n:s:o:" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    s) STORE_NAME="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    *) echo "Usage: $0 [-n namespace] [-s store-name] [-o output-dir]"; exit 1 ;;
  esac
done

NS_FLAG=""
[ -n "$NAMESPACE" ] && NS_FLAG="-n $NAMESPACE" || NS_FLAG="-A"

echo "Scanning for ExternalSecrets using store: $STORE_NAME"
echo "======================================================="
echo ""

# Get all ExternalSecrets as JSON
ES_LIST=$($KUBECTL get externalsecrets $NS_FLAG -o json 2>/dev/null)
TOTAL=$(echo "$ES_LIST" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))")
echo "Total ExternalSecrets found: $TOTAL"
echo ""

# Filter to ones using the target store
echo "$ES_LIST" | python3 -c "
import sys, json, os

data = json.load(sys.stdin)
store_name = '$STORE_NAME'
output_dir = '$OUTPUT_DIR'

vault_es = []
for item in data.get('items', []):
    spec = item.get('spec', {})
    store_ref = spec.get('secretStoreRef', {})
    if store_ref.get('name') == store_name:
        vault_es.append(item)

if not vault_es:
    print(f'No ExternalSecrets found using store: {store_name}')
    sys.exit(0)

# Print inventory
print(f'ExternalSecrets using store \"{store_name}\": {len(vault_es)}')
print()
print(f'{\"NAMESPACE\":<20} {\"NAME\":<30} {\"TARGET SECRET\":<30} {\"KEYS\":<5}')
print('-' * 85)

total_keys = 0
by_namespace = {}

for item in vault_es:
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    target = item['spec'].get('target', {}).get('name', name)
    keys = len(item['spec'].get('data', []))
    total_keys += keys
    print(f'{ns:<20} {name:<30} {target:<30} {keys:<5}')

    if ns not in by_namespace:
        by_namespace[ns] = []
    by_namespace[ns].append(item)

print()
print(f'Total: {len(vault_es)} ExternalSecrets, {total_keys} secret keys, {len(by_namespace)} namespaces')
print()

# Generate Akeyless ExternalSecret YAMLs
print('=' * 60)
print('Generated Akeyless ExternalSecret YAMLs')
print('=' * 60)
print()

for ns, items in sorted(by_namespace.items()):
    yamls = []
    for item in items:
        spec = item['spec']
        name = item['metadata']['name']
        target = spec.get('target', {})
        target_name = target.get('name', name)
        creation_policy = target.get('creationPolicy', 'Owner')
        refresh = spec.get('refreshInterval', '1m')

        # Convert Vault remoteRefs to Akeyless format
        akl_data = []
        for entry in spec.get('data', []):
            secret_key = entry['secretKey']
            remote = entry['remoteRef']
            vault_key = remote.get('key', '')
            vault_prop = remote.get('property', '')

            # Vault: key=demo-app/database, property=host
            # Akeyless: key=/demo-app/database, property=host (same structure, just add / prefix)
            akl_key = f'/{vault_key}'
            akl_entry = {'secretKey': secret_key, 'remoteRef': {'key': akl_key}}
            if vault_prop:
                akl_entry['remoteRef']['property'] = vault_prop
            akl_data.append(akl_entry)

        # Build YAML manually (avoid PyYAML dependency)
        lines = [
            'apiVersion: external-secrets.io/v1',
            'kind: ExternalSecret',
            'metadata:',
            f'  name: akl-{name}',
            f'  namespace: {ns}',
            '  labels:',
            '    migration-source: akeyless',
            'spec:',
            f'  refreshInterval: {refresh}',
            '  secretStoreRef:',
            '    name: akeyless',
            '    kind: ClusterSecretStore',
            '  target:',
            f'    name: {target_name}',
            f'    creationPolicy: {creation_policy}',
            '  data:',
        ]
        for d in akl_data:
            lines.append(f'    - secretKey: {d[\"secretKey\"]}')
            lines.append(f'      remoteRef:')
            lines.append(f'        key: {d[\"remoteRef\"][\"key\"]}')
            if 'property' in d['remoteRef']:
                lines.append(f'        property: {d[\"remoteRef\"][\"property\"]}')

        yamls.append('\n'.join(lines))

    combined = '\n---\n'.join(yamls)

    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
        filepath = os.path.join(output_dir, f'{ns}-akeyless-externalsecrets.yaml')
        with open(filepath, 'w') as f:
            f.write(combined + '\n')
        print(f'  Written: {filepath}')
    else:
        print(f'# --- Namespace: {ns} ---')
        print(combined)
        print()
"
