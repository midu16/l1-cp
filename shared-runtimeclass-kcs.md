# How to allow a pod on nodes from two different MCPs with PerformanceProfiles applied

**Document type:** Knowledge Center Solution (KCS)  
**Component:** OpenShift Container Platform, Performance Addon Operator (PAO) / Node Tuning Operator (NTO), CRI-O, RuntimeClass  
**Audience:** Cluster administrators, platform engineers

---

## Issue

A workload (Pod) that uses a performance-oriented runtime (RuntimeClass) and CRI-O performance annotations can only be scheduled onto nodes that match the **single** MachineConfigPool (MCP) targeted by the corresponding PerformanceProfile. For example, a pod using `runtimeClassName: performance-mno-wp-sched-master` runs only on master nodes; it cannot be scheduled on worker nodes that use a different PerformanceProfile (e.g. `performance-mno-wp-sched-worker`).

**Requirement:** Schedule the same performance-sensitive workload onto nodes that belong to **two different MCPs** (e.g. both masters and workers) that each have their own PerformanceProfile applied, without maintaining two separate pod specs or runtime class names.

---

## Environment

- **Product:** Red Hat OpenShift Container Platform 4.x (validated on 4.18.x, Kubernetes 1.31.x)
- **Relevant components:**
  - Performance Addon Operator (PAO) / Node Tuning Operator (NTO) — `performance.openshift.io/v2` PerformanceProfile
  - CRI-O with high-performance handler and workload annotations (e.g. `cpu-quota.crio.io`, `cpu-load-balancing.crio.io`, `irq-load-balancing.crio.io`)
  - Kubernetes RuntimeClass (`node.k8s.io/v1`)
- **Topology:** Multiple control-plane (master) nodes and worker nodes; each pool has its own PerformanceProfile (e.g. one for `node-role.kubernetes.io/master`, one for `node-role.kubernetes.io/worker`).
- **Prerequisites:** Cluster up and running; NTO/PAO installed; PerformanceProfiles applied per MCP as needed.

---

## Cause

Each PerformanceProfile creates a **distinct** RuntimeClass (e.g. `performance-mno-wp-sched-master`, `performance-mno-wp-sched-worker`) with a **pool-specific** node selector. The scheduler uses the RuntimeClass `scheduling.nodeSelector` to place pods only on nodes that belong to that profile’s MCP. A pod that specifies one profile’s RuntimeClass is therefore restricted to that pool; there is no built-in way to “share” one runtime class name across multiple MCPs.

---

## Resolution

Use a **custom shared RuntimeClass** that:

1. Uses the same CRI-O **handler** as the performance profiles (`high-performance`).
2. Uses a **common node selector** (e.g. `common-runtimeclass-node=""`) that is applied to **all** nodes (masters and workers) that are configured with a PerformanceProfile and should run this workload.

Then:

- Label those nodes with the common label.
- Create the shared RuntimeClass with that label in `scheduling.nodeSelector`.
- Use `runtimeClassName: common-runtime-class` (or your chosen name) in the pod spec so the pod can be scheduled on any of the labeled nodes.

Optional: If control-plane nodes are not schedulable by default, make masters schedulable via the cluster Scheduler config before applying the common label and running workloads there.

---

### Procedure overview

1. **(Optional)** Make control-plane nodes schedulable (if you need to run the workload on masters).
2. Label every node that should run the shared performance workload with a common label (e.g. `common-runtimeclass-node=""`).
3. Create the shared RuntimeClass that uses `handler: high-performance` and the same common label in `scheduling.nodeSelector`.
4. Create pods with `runtimeClassName: common-runtime-class` (and any required CRI-O annotations).

---

### Step 1 — (Optional) Make master nodes schedulable

If the workload must run on control-plane nodes, configure the cluster Scheduler so masters are schedulable.

**Apply the Scheduler configuration:**


```bash
oc apply -f master-scheduler.yaml
```

Expected output: `scheduler.config.openshift.io/cluster configured`

**Verify:**

```bash
oc get nodes
```

Control-plane nodes should show both `control-plane,master` and `worker` in ROLES, and `oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{.spec.taints}{"\n\n"}{end}'` should show no (or empty) taints for masters if they are now schedulable.

**Reference file: `master-scheduler.yaml`**

```yaml
apiVersion: config.openshift.io/v1
kind: Scheduler
metadata:
  name: cluster
spec:
  mastersSchedulable: true
```

---

### Step 2 — Label nodes for the shared RuntimeClass

Label all nodes that are configured with a PerformanceProfile and should run the shared performance workload:

```bash
oc get nodes -o name | xargs -I {} oc label {} common-runtimeclass-node=""
```

Or label individually:

```bash
oc label node <master1> common-runtimeclass-node=""
oc label node <master2> common-runtimeclass-node=""
oc label node <worker1> common-runtimeclass-node=""
# ... repeat for each node
```

**Verify:**

```bash
oc get nodes --show-labels
```

Each of those nodes should include `common-runtimeclass-node=` in LABELS.

---

### Step 3 — Create the shared RuntimeClass

Create the RuntimeClass that uses the CRI-O high-performance handler and the common node selector:

```bash
oc create -f common-runtimeclass-node.yaml
```

Expected output: `runtimeclass.node.k8s.io/common-runtime-class created`


**Verify:**

```bash
oc get runtimeclass
# or
oc get runtimeclass -A
```

Example:

```
NAME                       HANDLER            AGE
common-runtime-class       high-performance   <age>
```

**Reference file: `common-runtimeclass-node.yaml`**

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: common-runtime-class
handler: high-performance
scheduling:
  nodeSelector:
    common-runtimeclass-node: ""
```

---

### Step 4 — Apply PerformanceProfiles (if not already applied)

Ensure each MCP has its PerformanceProfile applied (e.g. master pool and worker pool). Example:

```bash
oc create -f master-pao.yaml
oc create -f worker-pao.yaml
```

Example output:

```
performanceprofile.performance.openshift.io/mno-wp-sched-master created
performanceprofile.performance.openshift.io/mno-wp-sched-worker created
```

**Reference file: `master-pao.yaml`**

```yaml
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: mno-wp-sched-master
spec:
  cpu:
    isolated: 16-55,72-111
    reserved: 0-15,56-71
  nodeSelector:
    node-role.kubernetes.io/master: ""
# status.runtimeClass is set by the operator, e.g. performance-mno-wp-sched-master
```

**Reference file: `worker-pao.yaml`**

```yaml
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: mno-wp-sched-worker
spec:
  cpu:
    isolated: 16-55,72-111
    reserved: 0-15,56-71
  nodeSelector:
    node-role.kubernetes.io/worker: ""
# status.runtimeClass is set by the operator, e.g. performance-mno-wp-sched-worker
```

---

### Step 5 — Run a pod using the shared RuntimeClass

Create a pod that uses the shared RuntimeClass and the required CRI-O annotations:

```bash
oc create -f common-runtime-class-pod.yaml
```

**Verify placement:**

```bash
oc get pods -n test-ns -o wide
```

The pod can be scheduled on any node that has the label `common-runtimeclass-node=""` (e.g. on a worker or, if masters are schedulable, on a control-plane node). To test placement on a specific node, add `nodeName: <node-fqdn>` to the pod spec.

**Reference file: `common-runtime-class-pod.yaml`**

```yaml
---
# This YAML file defines a Namespace for the Pod
apiVersion: v1
kind: Namespace
metadata:
  name: test-ns
---
# This YAML file defines a Pod that uses the shared performance runtime class
apiVersion: v1
kind: Pod
metadata:
  name: test
  namespace: test-ns
  annotations:
    cpu-quota.crio.io: "disable"              # Disable CFS cpu quota accounting
    cpu-load-balancing.crio.io: "disable"     # Disable CPU balance with CRIO
    irq-load-balancing.crio.io: "disable"     # Opt-out from interrupt handling
spec:
  runtimeClassName: common-runtime-class
  containers:
    - name: main
      image: registry.access.redhat.com/ubi8-micro:latest
      command: ["/bin/sh", "-c", "--"]
      args: ["while true; do sleep 99999999; done;"]
      resources:
        limits:
          memory: "2Gi"
          cpu: "4"
```

---

### Validation summary (example cluster)

On an OpenShift 4.18 cluster with 3 control-plane and 2 worker nodes:

- After applying `master-scheduler.yaml`, masters show as schedulable (e.g. ROLES include `worker`).
- After labeling nodes with `common-runtimeclass-node=""` and creating `common-runtimeclass-node.yaml`, `oc get runtimeclass` shows `common-runtime-class` with handler `high-performance`.
- After applying `master-pao.yaml` and `worker-pao.yaml`, NTO creates pool-specific RuntimeClasses (`performance-mno-wp-sched-master`, `performance-mno-wp-sched-worker`) and corresponding MachineConfigs (e.g. `50-performance-mno-wp-sched-master`, `50-performance-mno-wp-sched-worker`).
- A pod using `runtimeClassName: common-runtime-class` (e.g. from `common-runtime-class-pod.yaml`) can run on either a worker or a control-plane node, depending on scheduler placement or `nodeName` override.

**Contrast with pool-specific RuntimeClass:** A pod using `runtimeClassName: performance-mno-wp-sched-master` is restricted by that RuntimeClass’s node selector to master nodes. If you pin that pod to a worker (e.g. with `nodeName: example-worker-0.example.com`), the scheduler/node affinity still enforces the master selector and the pod can fail with a NodeAffinity predicate error. Using the shared `common-runtime-class` avoids that and allows the same pod spec to run on both pools.

---

## Reference — Pod using pool-specific RuntimeClass (comparison)

For comparison, a pod that uses the **pool-specific** RuntimeClass (only master nodes) is shown below. This pod **cannot** be scheduled on workers when using this RuntimeClass.

**Reference file: `performance-mno-wp-sched-master-pod.yaml`**

```yaml
---
# This YAML file defines a Namespace for the Pod
apiVersion: v1
kind: Namespace
metadata:
  name: test-ns
---
# This YAML file defines a Pod that uses the performance runtime class (master pool only)
apiVersion: v1
kind: Pod
metadata:
  name: test
  namespace: test-ns
  annotations:
    cpu-quota.crio.io: "disable"              # Disable CFS cpu quota accounting
    cpu-load-balancing.crio.io: "disable"     # Disable CPU balance with CRIO
    irq-load-balancing.crio.io: "disable"     # Opt-out from interrupt handling
spec:
  runtimeClassName: performance-mno-wp-sched-master  # Map to the correct performance class
  containers:
    - name: main
      image: registry.access.redhat.com/ubi8-micro:latest
      command: ["/bin/sh", "-c", "--"]
      args: ["while true; do sleep 99999999; done;"]
      resources:
        limits:
          memory: "2Gi"
          cpu: "4"
```

---

## Summary table of referenced files

| File | Purpose |
|------|---------|
| `master-scheduler.yaml` | Scheduler config to make control-plane nodes schedulable. |
| `common-runtimeclass-node.yaml` | Shared RuntimeClass with `handler: high-performance` and `scheduling.nodeSelector.common-runtimeclass-node: ""`. |
| `master-pao.yaml` | PerformanceProfile for master MCP (`mno-wp-sched-master`). |
| `worker-pao.yaml` | PerformanceProfile for worker MCP (`mno-wp-sched-worker`). |
| `common-runtime-class-pod.yaml` | Example namespace + pod using `runtimeClassName: common-runtime-class` (runs on both pools). |
| `performance-mno-wp-sched-master-pod.yaml` | Example namespace + pod using pool-specific RuntimeClass (masters only). |

---

## Additional resources

- [RuntimeClass scheduling](https://kubernetes.io/docs/concepts/containers/runtime-class/#scheduling) — Kubernetes documentation.
- Red Hat OpenShift Container Platform documentation: *Scalability and performance* and *Node Tuning Operator* / *Performance Addon Operator*.
- Product documentation for your OCP version (e.g. 4.18) for PerformanceProfile and CRI-O workload annotations.
