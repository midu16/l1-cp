# Network Connectivity Tester

A DaemonSet-based network connectivity tester for OpenShift Hub clusters. Deploys a pod on every node that continuously tests network connectivity to a specified gateway and logs the results.

## Features

- **DaemonSet deployment** - One pod per node, automatically scales with cluster
- **Continuous testing** - Runs indefinitely, logging results until stopped
- **Multiple test types:**
  - ICMP ping with latency measurement
  - TCP port connectivity
  - DNS resolution
  - MTU path discovery
  - Default route verification
- **Configurable via environment variables**
- **Non-privileged execution** (only NET_RAW capability for ping)

## Quick Start

### 1. Build the Container Image

```bash
cd network-tester

# Build with podman
podman build -t network-tester:latest -f Containerfile .
```

### 2. Push to Your Registry

```bash
# Tag for your registry
podman tag network-tester:latest quay.io/your-org/network-tester:latest

# Push
podman push quay.io/your-org/network-tester:latest
```

### 3. Update the Deployment Manifest

Edit `deployment.yaml` or use kustomize:

```yaml
# Update the image
image: quay.io/your-org/network-tester:latest

# Update the gateway IP
- name: GATEWAY_IP
  value: "172.16.30.1"  # Your machine network gateway
```

### 4. Deploy to OpenShift

```bash
# Using kubectl/oc directly
oc apply -f deployment.yaml

# Or using kustomize
oc apply -k .
```

### 5. View the Logs

```bash
# View logs from all pods
oc logs -n network-tester -l app=network-tester -f --all-containers

# View logs from a specific node's pod
oc logs -n network-tester -l app=network-tester --field-selector spec.nodeName=<node-name> -f

# View logs with timestamps
oc logs -n network-tester -l app=network-tester --timestamps -f
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GATEWAY_IP` | `192.168.1.1` | **Required**: Machine network gateway to test |
| `TEST_INTERVAL` | `10` | Seconds between test cycles |
| `PING_COUNT` | `3` | Number of ICMP pings per test |
| `PING_TIMEOUT` | `2` | ICMP ping timeout in seconds |
| `TCP_PORTS` | `22,80,443` | Comma-separated TCP ports to test |
| `DNS_TEST_HOST` | `kubernetes.default.svc.cluster.local` | Hostname for DNS resolution test |
| `LOG_LEVEL` | `INFO` | Log verbosity level |

### Example: Custom Configuration

```yaml
env:
  - name: GATEWAY_IP
    value: "10.0.0.1"
  - name: TEST_INTERVAL
    value: "60"
  - name: TCP_PORTS
    value: "22,80,443,8080,6443"
  - name: DNS_TEST_HOST
    value: "api.openshift.example.com"
```

## Log Output Format

```
[2026-02-18 10:30:00] [INFO] [node-1] === Connectivity Test Cycle #1 ===
[2026-02-18 10:30:00] [INFO] [node-1] Node: node-1
[2026-02-18 10:30:00] [INFO] [node-1] Pod: network-tester-abc123
[2026-02-18 10:30:00] [INFO] [node-1] Pod IP: 10.128.0.15
[2026-02-18 10:30:00] [INFO] [node-1] Target Gateway: 172.16.30.1
[2026-02-18 10:30:00] [INFO] [node-1] --- ICMP Connectivity ---
[2026-02-18 10:30:01] [OK] [node-1] ICMP ping to 172.16.30.1: OK (avg latency: 0.5ms)
[2026-02-18 10:30:01] [INFO] [node-1] --- TCP Port Connectivity ---
[2026-02-18 10:30:01] [OK] [node-1] TCP port 22 to 172.16.30.1: OPEN
[2026-02-18 10:30:02] [OK] [node-1] TCP port 80 to 172.16.30.1: OPEN
[2026-02-18 10:30:02] [FAIL] [node-1] TCP port 443 to 172.16.30.1: CLOSED/FILTERED
```

## Monitoring and Alerts

### View Pod Status

```bash
# Check DaemonSet status
oc get daemonset -n network-tester

# Expected output (for 3-node cluster):
# NAME             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
# network-tester   3         3         3       3            3
```

### Check Pod Distribution

```bash
# See which node each pod is running on
oc get pods -n network-tester -o wide

# Expected output:
# NAME                   READY   STATUS    NODE
# network-tester-abc12   1/1     Running   master-0
# network-tester-def34   1/1     Running   master-1
# network-tester-ghi56   1/1     Running   master-2
```

### Stream Logs from All Nodes

```bash
# Follow logs from all pods simultaneously
oc logs -n network-tester -l app=network-tester -f --max-log-requests=10

# Filter for failures only
oc logs -n network-tester -l app=network-tester --since=1h | grep FAIL
```

## Troubleshooting

### Pods Not Starting

```bash
# Check pod events
oc describe pod -n network-tester -l app=network-tester

# Check for image pull issues
oc get events -n network-tester --sort-by='.lastTimestamp'
```

### Permission Issues with Ping

The container needs `NET_RAW` capability for ICMP ping. If using a restrictive SCC:

```bash
# Check current SCC
oc get pod -n network-tester -o yaml | grep -A5 securityContext

# If needed, create a custom SCC or use net-raw-capability
oc adm policy add-scc-to-user privileged -z network-tester -n network-tester
```

### Test Script Manually

```bash
# Exec into a pod to debug
oc exec -it -n network-tester $(oc get pod -n network-tester -o name | head -1) -- /bin/bash

# Run individual tests
ping -c 3 172.16.30.1
nc -zv 172.16.30.1 22
nslookup kubernetes.default.svc.cluster.local
```

## Cleanup

```bash
# Delete all resources
oc delete -f deployment.yaml

# Or using kustomize
oc delete -k .

# Verify cleanup
oc get all -n network-tester
```

## File Structure

```
network-tester/
├── Containerfile           # Container image definition
├── connectivity-test.sh    # Main test script
├── deployment.yaml         # Kubernetes manifests (DaemonSet, SA, NS)
├── kustomization.yaml      # Kustomize configuration
└── README.md               # This file
```

## Integration with ArgoCD

To deploy via ArgoCD, create an Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: network-tester
  namespace: openshift-gitops
spec:
  destination:
    namespace: network-tester
    server: https://kubernetes.default.svc
  project: default
  source:
    path: network-tester
    repoURL: https://github.com/your-org/l1-cp.git
    targetRevision: main
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Future development

- [ ] **SRIOV** - Enhance the network-tester:latest with validating the connectivity through a given sriov (netdev, dpdk) interface.