# Webcache Deployment for RHCOS ISO Caching

This deployment provides a web server running in OpenShift/Kubernetes that caches RHCOS ISO and rootfs images, accessible at `http://infra.5g-deployment.lab:8080/`.

## Components

1. **Namespace**: `webcache` - Isolates the webcache resources
2. **PVC**: `webcache-storage` - Persistent storage (50Gi) for ISO files
3. **ConfigMap**: `webcache-config` - Apache httpd configuration
4. **Deployment**: `webcache` - Main deployment with:
   - InitContainer: Downloads RHCOS ISO files on first startup
   - Container: Apache httpd server serving the cached files
5. **Service**: `webcache` - NodePort service for external access
6. **Route**: `webcache` - OpenShift Route for internal cluster access

## Prerequisites

- OpenShift 4.x cluster
- Storage class available (default: `lvms-vg1`, update in `01_pvc.yaml` if different)
- Network access to download RHCOS images from mirror.openshift.com
- DNS resolution for `infra.5g-deployment.lab` pointing to the cluster node or load balancer

## Deployment Steps

1. **Update Storage Class** (if needed):
   ```bash
   # Check available storage classes
   oc get storageclass
   
   # Update 01_pvc.yaml with your storage class name
   ```

2. **Deploy the resources** (using Kustomize - recommended):
   ```bash
   oc apply -k .
   ```
   
   Or using kustomize build:
   ```bash
   oc kustomize . | oc apply -f -
   ```

   Alternative: Deploy individual files:
   ```bash
   oc apply -f 00_namespace.yaml
   oc apply -f 01_pvc.yaml
   oc apply -f 02_configmap.yaml
   oc apply -f 03_deployment.yaml
   oc apply -f 04_service.yaml
   oc apply -f 05_route_node0.yaml
   oc apply -f 05_route_node1.yaml
   oc apply -f 05_route_node2.yaml
   ```

3. **Check deployment status**:
   ```bash
   oc get pods -n webcache
   oc logs -n webcache -l app=webcache -c download-iso  # Check init container logs
   oc logs -n webcache -l app=webcache -c httpd         # Check httpd logs
   ```

4. **Get the NodePort**:
   ```bash
   oc get svc -n webcache webcache
   # Note the NodePort value (e.g., 30080)
   ```

5. **Access the webcache**:
   - Via NodePort: `http://<node-ip>:<nodeport>/`
   - Via Route: `http://infra.5g-deployment.lab:8080/` (if DNS and ingress are configured)
   - Via Route (HTTPS): `https://infra.5g-deployment.lab/` (if using the Route)

## External Access Configuration

### Option 1: NodePort + HAProxy (Recommended for this lab)
The service is configured as NodePort. To make it accessible at `http://infra.5g-deployment.lab:8080/`:

1. **Get the NodePort**:
   ```bash
   NODEPORT=$(oc get svc webcache -n webcache -o jsonpath='{.spec.ports[0].nodePort}')
   echo "NodePort: $NODEPORT"
   ```

2. **Get a cluster node IP**:
   ```bash
   NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
   echo "Node IP: $NODE_IP"
   ```

3. **Configure HAProxy** (on your hypervisor):
   Add the following to your HAProxy configuration (`/etc/haproxy/haproxy.cfg`):
   ```haproxy
   frontend webcache-8080
       bind :8080
       mode http
       default_backend be_webcache_8080

   backend be_webcache_8080
       mode http
       balance roundrobin
       server webcache1 <NODE_IP>:<NODEPORT> check
   ```
   
   Replace `<NODE_IP>` and `<NODEPORT>` with the actual values from steps 1-2.
   
   Then restart HAProxy:
   ```bash
   systemctl restart haproxy
   # or if using podman
   podman restart haproxy
   ```

4. **Verify DNS**:
   Ensure `infra.5g-deployment.lab` resolves to your HAProxy/hypervisor IP (192.168.125.1).

### Option 2: Direct NodePort Access
You can access it directly via any cluster node IP on the assigned port:
```bash
NODEPORT=$(oc get svc webcache -n webcache -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl http://$NODE_IP:$NODEPORT/
```

To use a specific NodePort (e.g., 30080), you can edit the service:
```bash
oc patch svc webcache -n webcache --type='json' -p='[{"op": "add", "path": "/spec/ports/0/nodePort", "value": 30080}]'
```

### Option 3: LoadBalancer
If you have a LoadBalancer provider (like MetalLB), use `06_service_loadbalancer.yaml` instead of `04_service.yaml`.

### Option 4: Route + External Access
The Route (`05_route.yaml`) provides HTTPS access. To make it accessible externally:
- Configure your ingress controller to expose routes externally
- Update DNS to point `infra.5g-deployment.lab` to the ingress controller IP
- Or use a wildcard DNS entry for `*.apps.hub.5g-deployment.lab`

## Customizing ISO Downloads

To add or modify ISO versions, edit the `initContainers` section in `03_deployment.yaml`:

```yaml
initContainers:
- name: download-iso
  # ... update the download URLs and filenames
```

## Troubleshooting

1. **PVC not binding**:
   ```bash
   oc describe pvc webcache-storage -n webcache
   # Check if storage class exists and has available PVs
   ```

2. **Init container failing**:
   ```bash
   oc logs -n webcache <pod-name> -c download-iso
   # Check if network access to mirror.openshift.com is available
   ```

3. **Service not accessible**:
   ```bash
   oc get svc -n webcache
   oc get endpoints -n webcache
   # Verify pods are running and endpoints are created
   ```

4. **Route not working**:
   ```bash
   oc describe route webcache -n webcache
   # Check if DNS is configured correctly
   ```

## Updating AgentServiceConfig

After deployment, ensure your `AgentServiceConfig` references the correct URLs:

```yaml
osImages:
- cpuArchitecture: x86_64
  openshiftVersion: "4.18"
  rootFSUrl: http://infra.5g-deployment.lab:8080/rhcos-4.18.1-x86_64-live-rootfs.x86_64.img
  url: http://infra.5g-deployment.lab:8080/rhcos-4.18.1-x86_64-live.x86_64.iso
  version: 418.XX.XXXXXX-0
```

## Storage Considerations

- The PVC is set to 50Gi, which should be sufficient for multiple RHCOS versions
- ISO files are typically 1-2GB each, rootfs images are smaller
- Adjust the PVC size in `01_pvc.yaml` if needed
