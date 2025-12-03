# Quay Registry PVC Storage Class Fix

## Problem
The Quay operator creates PersistentVolumeClaims (PVCs) for PostgreSQL databases without specifying a storage class. This causes the PVCs to remain in `Pending` state when no default storage class is configured, preventing the Quay registry pods from starting.

## Solution
Patch the PVCs created by the Quay operator to use the `ocs-storagecluster-ceph-rbd` storage class.

## Affected PVCs
- `quay-registry-clair-postgres-*` (Clair PostgreSQL database)
- `quay-registry-quay-postgres-*` (Quay PostgreSQL database)

Note: The version numbers in PVC names (e.g., `-15`, `-13`) may vary.

## How to Apply the Fix

### Option 1: Use the Patch Script (Recommended)
```bash
cd /home/midu/Documents/l1-cp/hub-config/operators-config
./patch-quay-pvcs.sh
```

The script automatically finds and patches PVCs using label selectors, so it works even if PVC names change.

### Option 2: Manual Patch Commands
```bash
# Patch clair-postgres PVC
oc patch pvc quay-registry-clair-postgres-15 -n quay-operator \
  -p '{"spec":{"storageClassName":"ocs-storagecluster-ceph-rbd"}}'

# Patch quay-postgres PVC
oc patch pvc quay-registry-quay-postgres-13 -n quay-operator \
  -p '{"spec":{"storageClassName":"ocs-storagecluster-ceph-rbd"}}'
```

### Option 3: Apply Patch File (if PVC names match)
```bash
oc apply -f 99_05_quay-pvc-storageclass-patch.yaml
```

## When to Apply
Apply this fix after:
1. The QuayRegistry CR is created
2. The Quay operator has created the PVCs
3. Before the pods need to start (they will be stuck in Pending otherwise)

## Verification
After applying the fix, verify the PVCs are bound:
```bash
oc get pvc -n quay-operator -l 'quay-component in (clair-postgres,postgres)'
```

Expected output:
```
NAME                              STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS                  AGE
quay-registry-clair-postgres-15   Bound    pvc-...  50Gi       RWO            ocs-storagecluster-ceph-rbd   ...
quay-registry-quay-postgres-13    Bound    pvc-...  50Gi       RWO            ocs-storagecluster-ceph-rbd   ...
```

## Files
- `99_05_quay-pvc-storageclass-patch.yaml` - Patch manifest for PVCs
- `patch-quay-pvcs.sh` - Automated script to patch PVCs using label selectors
- `README-quay-pvc-fix.md` - This documentation

## Future Considerations
If the Quay operator adds support for configuring storage classes in the QuayRegistry CR, this manual patching approach can be replaced with a declarative configuration.
