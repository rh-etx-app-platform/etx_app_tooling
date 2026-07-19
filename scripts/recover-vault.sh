#!/bin/bash

set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_RELEASE="${VAULT_RELEASE:-etx-vault}"
VAULT_POD="${VAULT_POD:-${VAULT_RELEASE}-0}"
BOOTSTRAP_SECRET="${BOOTSTRAP_SECRET:-etx-vault-bootstrap}"

if ! command -v oc >/dev/null 2>&1; then
  echo "oc CLI not found" >&2
  exit 1
fi

echo "Checking Vault pod ${VAULT_POD} in namespace ${NAMESPACE}..."
until oc get pod "${VAULT_POD}" -n "${NAMESPACE}" >/dev/null 2>&1; do
  sleep 5
done

until [ "$(oc get pod "${VAULT_POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')" = "Running" ]; do
  sleep 5
done

STATUS_JSON=$(oc exec -n "${NAMESPACE}" "${VAULT_POD}" -- sh -c 'vault status -format=json || true')
SEALED=$(printf '%s' "${STATUS_JSON}" | grep -o '"sealed":[^,}]*' | cut -d':' -f2 | tr -d ' ')
INITIALIZED=$(printf '%s' "${STATUS_JSON}" | grep -o '"initialized":[^,}]*' | cut -d':' -f2 | tr -d ' ')

if [ "${INITIALIZED}" != "true" ]; then
  echo "Vault is not initialized. Re-run the bootstrap before attempting recovery." >&2
  exit 1
fi

if [ "${SEALED}" != "true" ]; then
  echo "Vault is already unsealed."
  exit 0
fi

UNSEAL_KEY=$(oc get secret "${BOOTSTRAP_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.unseal-key}' | base64 -d)

echo "Unsealing Vault..."
oc exec -n "${NAMESPACE}" "${VAULT_POD}" -- vault operator unseal "${UNSEAL_KEY}" >/dev/null

FINAL_STATUS=$(oc exec -n "${NAMESPACE}" "${VAULT_POD}" -- sh -c 'vault status -format=json || true')
FINAL_SEALED=$(printf '%s' "${FINAL_STATUS}" | grep -o '"sealed":[^,}]*' | cut -d':' -f2 | tr -d ' ')

if [ "${FINAL_SEALED}" = "true" ]; then
  echo "Vault is still sealed after recovery attempt." >&2
  exit 1
fi

echo "Vault is unsealed and ready."
