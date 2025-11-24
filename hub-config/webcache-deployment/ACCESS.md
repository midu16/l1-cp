# Webcache Service Access Guide

## Current Service Configuration

- **Service Type**: NodePort
- **Internal Port**: 8080
- **NodePort**: 31415
- **Cluster IP**: 172.22.99.45

## Access Methods

### Method 1: Via NodePort (Direct Node Access)

Access the service directly using any cluster node IP and the NodePort:

```bash
# Using any control plane node IP
curl http://172.16.30.20:31415/
curl http://172.16.30.21:31415/
curl http://172.16.30.22:31415/

# Or using node hostnames
curl http://hub-ctlplane-0.hub.5g-deployment.lab:31415/
curl http://hub-ctlplane-1.hub.5g-deployment.lab:31415/
curl http://hub-ctlplane-2.hub.5g-deployment.lab:31415/
```

**From a web browser:**
- `http://172.16.30.20:31415/`
- `http://172.16.30.21:31415/`
- `http://172.16.30.22:31415/`

### Method 2: Via OpenShift Routes (HTTPS)

The service is exposed via OpenShift Routes on all three control plane nodes:

```bash
# HTTPS access (edge termination with redirect)
curl -k https://hub-ctlplane-0.hub.5g-deployment.lab/
curl -k https://hub-ctlplane-1.hub.5g-deployment.lab/
curl -k https://hub-ctlplane-2.hub.5g-deployment.lab/

# HTTP access (redirects to HTTPS)
curl http://hub-ctlplane-0.hub.5g-deployment.lab/
curl http://hub-ctlplane-1.hub.5g-deployment.lab/
curl http://hub-ctlplane-2.hub.5g-deployment.lab/
```

**From a web browser:**
- `https://hub-ctlplane-0.hub.5g-deployment.lab/`
- `https://hub-ctlplane-1.hub.5g-deployment.lab/`
- `https://hub-ctlplane-2.hub.5g-deployment.lab/`

### Method 3: Via Cluster IP (Internal Only)

From within the cluster (pods, other services):

```bash
# Using service name (DNS resolution)
curl http://webcache.webcache.svc.cluster.local:8080/

# Or using short name within the same namespace
curl http://webcache:8080/
```

### Method 4: Port Forward (Local Access)

Forward the service port to your local machine:

```bash
oc port-forward svc/webcache -n webcache 8080:8080
```

Then access via:
```bash
curl http://localhost:8080/
```

**From a web browser:**
- `http://localhost:8080/`

## Quick Access Commands

### Get NodePort dynamically:
```bash
NODEPORT=$(oc get svc webcache -n webcache -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort: $NODEPORT"
```

### Get a node IP dynamically:
```bash
NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IP: $NODE_IP"
```

### Test access:
```bash
NODEPORT=$(oc get svc webcache -n webcache -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl http://$NODE_IP:$NODEPORT/
```

## Expected Content

Once the init container finishes downloading ISOs, you should see:

- An HTML index page listing available RHCOS ISO files
- Direct download links for:
  - `rhcos-4.18.1-x86_64-live.x86_64.iso`
  - `rhcos-4.18.1-x86_64-live-rootfs.x86_64.img`
  - `rhcos-4.14.0-x86_64-live.x86_64.iso`
  - `rhcos-4.14.0-x86_64-live-rootfs.x86_64.img`
  - `rhcos-4.16.0-x86_64-live.x86_64.iso`
  - `rhcos-4.16.0-x86_64-live-rootfs.x86_64.img`

## Check Service Status

```bash
# Check if pods are ready
oc get pods -n webcache

# Check service endpoints
oc get endpoints -n webcache

# Check service details
oc describe svc webcache -n webcache

# Check route details
oc describe route webcache-node0 -n webcache
```

## Troubleshooting

### Service not accessible:

1. **Check if pods are running:**
   ```bash
   oc get pods -n webcache
   ```

2. **Check if init container completed:**
   ```bash
   oc logs -n webcache -l app=webcache -c download-iso
   ```

3. **Check if httpd container is running:**
   ```bash
   oc logs -n webcache -l app=webcache -c httpd
   ```

4. **Check service endpoints:**
   ```bash
   oc get endpoints webcache -n webcache
   ```

5. **Test from within cluster:**
   ```bash
   oc run test-pod --image=registry.access.redhat.com/ubi9/ubi-minimal:latest --rm -it --restart=Never -- curl http://webcache.webcache.svc.cluster.local:8080/
   ```

### Routes not working:

1. **Check route status:**
   ```bash
   oc get routes -n webcache
   oc describe route webcache-node0 -n webcache
   ```

2. **Check DNS resolution:**
   ```bash
   nslookup hub-ctlplane-0.hub.5g-deployment.lab
   ```

3. **Check ingress controller:**
   ```bash
   oc get pods -n openshift-ingress
   ```
