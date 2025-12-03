#!/bin/bash
# Script to patch Quay registry PVCs with the correct storage class
# This ensures PVCs created by the Quay operator use ocs-storagecluster-ceph-rbd storage class

set -e

NAMESPACE="${NAMESPACE:-quay-operator}"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd}"

echo "Patching Quay registry PVCs in namespace ${NAMESPACE} to use storage class ${STORAGE_CLASS}"

# Patch clair-postgres PVC
CLAIR_PVC=$(oc get pvc -n "${NAMESPACE}" -l quay-component=clair-postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${CLAIR_PVC}" ]; then
  echo "Patching PVC: ${CLAIR_PVC}"
  oc patch pvc "${CLAIR_PVC}" -n "${NAMESPACE}" -p "{\"spec\":{\"storageClassName\":\"${STORAGE_CLASS}\"}}"
else
  echo "Warning: No clair-postgres PVC found"
fi

# Patch quay-postgres PVC
QUAY_PVC=$(oc get pvc -n "${NAMESPACE}" -l quay-component=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${QUAY_PVC}" ]; then
  echo "Patching PVC: ${QUAY_PVC}"
  oc patch pvc "${QUAY_PVC}" -n "${NAMESPACE}" -p "{\"spec\":{\"storageClassName\":\"${STORAGE_CLASS}\"}}"
else
  echo "Warning: No quay-postgres PVC found"
fi

echo "Done. Verifying PVCs:"
oc get pvc -n "${NAMESPACE}" -l 'quay-component in (clair-postgres,postgres)'
