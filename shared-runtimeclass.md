# How to allow a pod on nodes from two different MCPs with PerformanceProfiles applied

## Table of Contents
- [How to allow a pod on nodes from two different MCPs with PerformanceProfiles applied](#how-to-allow-a-pod-on-nodes-from-two-different-mcps-with-performanceprofiles-applied)
  - [Table of Contents](#table-of-contents)
  - [Problem statement example](#problem-statement-example)
  - [Problem illustration](#problem-illustration)
  - [Proposed Solution - custom RuntimeClass](#proposed-solution---custom-runtimeclass)
    - [Pod using the new runtime class example can run on masters and workers](#pod-using-the-new-runtime-class-example-can-run-on-masters-and-workers)
  - [Proposed solution - validation](#proposed-solution---validation)

## Problem statement example

Given two EXAMPLE PerformanceProfiles that apply to two separate MachineConfigPools I want to create a workload specification that can be scheduled to both of them.


```bash
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
status:
 runtimeClass: performance-mno-wp-sched-master
```

and 

```bash
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
 name: mno-worker
spec:
 cpu:
   isolated: 16-55,72-111
   reserved: 0-15,56-71
 nodeSelector:
   node-role.kubernetes.io/worker: ""
status:
 runtimeClass: performance-mno-worker
```

## Problem illustration

The following pod CR example can only run on the master nodes:

```bash
apiVersion: v1
kind: Pod
metadata:
 name: test
 annotations:
   # Disable CFS cpu quota accounting
   cpu-quota.crio.io: "disable"
   # Disable CPU balance with CRIO
   cpu-load-balancing.crio.io: "disable"
   # Opt-out from interrupt handling
   irq-load-balancing.crio.io: "disable"
spec:
 # Map to the correct performance class
 runtimeClassName: performance-mno-wp-sched-master
 containers:
 - name: main
   image: registry.access.redhat.com/ubi8-micro:latest
   command: [ "/bin/sh", "-c", "--" ]
   args: [ "while true; do sleep 99999999; done;" ]
   resources:
     limits:
       memory: "2Gi"
       cpu: "4"
```

## Proposed Solution - custom RuntimeClass

We want to configure a pod that uses the isolation annotations to be able to run on both MCPs worker and master. The important piece of the solution is the handler name. CRI-O knows the high-performance handler and enables the workload annotations when it is used.
The scheduling limits where pods using this RuntimeClass can be scheduled to (https://kubernetes.io/docs/concepts/containers/runtime-class/#scheduling). It needs to point to nodes that were configured via a PerformanceProfile, otherwise CRI-O will refuse to use the high-performance handler.

You need to create a common label and apply it to all the nodes that are supposed to run workloads like this and that were configured via a performance profile.

```bash
oc label nodes master1.example.com common-runtimeclass-node=""
oc label nodes master2.example.com common-runtimeclass-node=""
oc label nodes master3.example.com common-runtimeclass-node=""
oc label nodes worker1.example.com common-runtimeclass-node=""
oc label nodes worker2.example.com common-runtimeclass-node=""
```

And then create a new RuntimeClass that uses this label

```bash
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
 name: common-runtime-class
handler: high-performance
scheduling:
 nodeSelector:
   common-runtimeclass-node: ""
```
### Pod using the new runtime class example can run on masters and workers

```bash
apiVersion: v1
kind: Pod
metadata:
 name: test
 …
spec:
 # Map to the correct performance class
 runtimeClassName: common-runtime-class
 …
```

## Proposed solution - validation

Taken in account the following Openshift 4.18 Cluster:

```bash
[root@INBACRNRDL0102 ~]# oc get nodes
NAME                               STATUS   ROLES                  AGE   VERSION
hub-ctlplane-0.5g-deployment.lab   Ready    control-plane,master   61m   v1.31.9
hub-ctlplane-1.5g-deployment.lab   Ready    control-plane,master   61m   v1.31.9
hub-ctlplane-2.5g-deployment.lab   Ready    control-plane,master   61m   v1.31.9
hub-worker-0.5g-deployment.lab     Ready    worker                 43m   v1.31.9
hub-worker-1.5g-deployment.lab     Ready    worker                 43m   v1.31.9
[root@INBACRNRDL0102 ~]# oc get clusterversion 
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.18.17   True        False         42m     Cluster version is 4.18.17
```

- Checking the cluster nodes labels: 

```bash
[root@INBACRNRDL0102 ~]# oc get nodes --show-labels
NAME                               STATUS   ROLES                  AGE   VERSION   LABELS
hub-ctlplane-0.5g-deployment.lab   Ready    control-plane,master   79m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-ctlplane-0.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=,node-role.kubernetes.io/master=,node.openshift.io/os_id=rhcos
hub-ctlplane-1.5g-deployment.lab   Ready    control-plane,master   79m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-ctlplane-1.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=,node-role.kubernetes.io/master=,node.openshift.io/os_id=rhcos
hub-ctlplane-2.5g-deployment.lab   Ready    control-plane,master   79m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-ctlplane-2.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=,node-role.kubernetes.io/master=,node.openshift.io/os_id=rhcos
hub-worker-0.5g-deployment.lab     Ready    worker                 61m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-worker-0.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/worker=,node.openshift.io/os_id=rhcos
hub-worker-1.5g-deployment.lab     Ready    worker                 61m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-worker-1.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/worker=,node.openshift.io/os_id=rhcos
```
- Checking the taints associated to the master nodes:

```bash
[root@INBACRNRDL0102 ~]# oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{.spec.taints}{"\n\n"}{end}'
hub-ctlplane-0.5g-deployment.lab
[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master"}]

hub-ctlplane-1.5g-deployment.lab
[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master"}]

hub-ctlplane-2.5g-deployment.lab
[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master"}]

hub-worker-0.5g-deployment.lab


hub-worker-1.5g-deployment.lab
```

- Making the `master` nodes as schedulable:

```bash
[root@INBACRNRDL0102 ~]# oc apply -f master-scheduler.yaml
scheduler.config.openshift.io/cluster configured
```
The [master-scheduler.yaml](./master-scheduler.yaml) reference. 

- Validating that the master nodes are schedulable now:

```bash
[root@INBACRNRDL0102 ~]# oc get nodes
NAME                               STATUS   ROLES                         AGE   VERSION
hub-ctlplane-0.5g-deployment.lab   Ready    control-plane,master,worker   93m   v1.31.9
hub-ctlplane-1.5g-deployment.lab   Ready    control-plane,master,worker   94m   v1.31.9
hub-ctlplane-2.5g-deployment.lab   Ready    control-plane,master,worker   93m   v1.31.9
hub-worker-0.5g-deployment.lab     Ready    worker                        76m   v1.31.9
hub-worker-1.5g-deployment.lab     Ready    worker                        76m   v1.31.9
[root@INBACRNRDL0102 ~]# oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{.spec.taints}{"\n\n"}{end}'
hub-ctlplane-0.5g-deployment.lab


hub-ctlplane-1.5g-deployment.lab


hub-ctlplane-2.5g-deployment.lab


hub-worker-0.5g-deployment.lab


hub-worker-1.5g-deployment.lab
```

- Label the nodes `common-runtimeclass-node` on all the nodes:
```bash
[root@INBACRNRDL0102 ~]# oc get nodes -o name | xargs -I {} oc label {} common-runtimeclass-node=""
node/hub-ctlplane-0.5g-deployment.lab labeled
node/hub-ctlplane-1.5g-deployment.lab labeled
node/hub-ctlplane-2.5g-deployment.lab labeled
node/hub-worker-0.5g-deployment.lab labeled
node/hub-worker-1.5g-deployment.lab labeled
```

- Validate that the label has been properly applied:
```bash
[root@INBACRNRDL0102 ~]# oc get nodes --show-labels
NAME                               STATUS   ROLES                         AGE   VERSION   LABELS
hub-ctlplane-0.5g-deployment.lab   Ready    control-plane,master,worker   96m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,common-runtimeclass-node=,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-ctlplane-0.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=,node-role.kubernetes.io/master=,node-role.kubernetes.io/worker=,node.openshift.io/os_id=rhcos
hub-ctlplane-1.5g-deployment.lab   Ready    control-plane,master,worker   96m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,common-runtimeclass-node=,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-ctlplane-1.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=,node-role.kubernetes.io/master=,node-role.kubernetes.io/worker=,node.openshift.io/os_id=rhcos
hub-ctlplane-2.5g-deployment.lab   Ready    control-plane,master,worker   96m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,common-runtimeclass-node=,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-ctlplane-2.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=,node-role.kubernetes.io/master=,node-role.kubernetes.io/worker=,node.openshift.io/os_id=rhcos
hub-worker-0.5g-deployment.lab     Ready    worker                        78m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,common-runtimeclass-node=,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-worker-0.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/worker=,node.openshift.io/os_id=rhcos
hub-worker-1.5g-deployment.lab     Ready    worker                        78m   v1.31.9   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,common-runtimeclass-node=,kubernetes.io/arch=amd64,kubernetes.io/hostname=hub-worker-1.5g-deployment.lab,kubernetes.io/os=linux,node-role.kubernetes.io/worker=,node.openshift.io/os_id=rhcos
```

- Create the `RuntimeClass CR`:
```bash
[root@INBACRNRDL0102 ~]# oc create -f common-runtimeclass-node.yaml 
runtimeclass.node.k8s.io/common-runtime-class created
```

The [common-runtimeclass-node.yaml](./common-runtimeclass-node.yaml) reference. 

- Validate the `RuntimeClass CR` creation:
```bash
[root@INBACRNRDL0102 ~]# oc get RuntimeClass -A
NAME                   HANDLER            AGE
common-runtime-class   high-performance   44s
```

- Applying the [master-pao.yaml](./master-pao.yaml) and [worker-pao.yaml](./worker-pao.yaml) to the cluster:
```bash
[root@INBACRNRDL0102 ~]# oc create -f master-pao.yaml
performanceprofile.performance.openshift.io/mno-wp-sched-master created
[root@INBACRNRDL0102 ~]# oc create -f worker-pao.yaml 
performanceprofile.performance.openshift.io/mno-wp-sched-worker created
```

- Cluster nodes getting rolling out the configuration:
```bash
[root@INBACRNRDL0102 ~]# oc get nodes -w
NAME                               STATUS                     ROLES                         AGE    VERSION
hub-ctlplane-0.5g-deployment.lab   Ready                      control-plane,master,worker   112m   v1.31.9
hub-ctlplane-1.5g-deployment.lab   Ready,SchedulingDisabled   control-plane,master,worker   113m   v1.31.9
hub-ctlplane-2.5g-deployment.lab   Ready                      control-plane,master,worker   112m   v1.31.9
hub-worker-0.5g-deployment.lab     Ready                      worker                        95m    v1.31.9
hub-worker-1.5g-deployment.lab     Ready,SchedulingDisabled   worker                        95m    v1.31.9
hub-ctlplane-1.5g-deployment.lab   Ready,SchedulingDisabled   control-plane,master,worker   113m   v1.31.9
hub-worker-0.5g-deployment.lab     Ready                      worker                        95m    v1.31.9
hub-ctlplane-1.5g-deployment.lab   Ready,SchedulingDisabled   control-plane,master,worker   113m   v1.31.9
hub-ctlplane-2.5g-deployment.lab   Ready                      control-plane,master,worker   113m   v1.31.9
```

- Validating that the configuration has been created:
```bash
[root@INBACRNRDL0102 ~]# oc get mc 
NAME                                               GENERATEDBYCONTROLLER                      IGNITIONVERSION   AGE
00-master                                          00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
00-worker                                          00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
01-master-container-runtime                        00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
01-master-kubelet                                  00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
01-worker-container-runtime                        00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
01-worker-kubelet                                  00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
50-nto-master                                                                                                   26m
50-nto-worker                                                                                                   26m
50-performance-mno-wp-sched-master                                                            3.2.0             26m
50-performance-mno-wp-sched-worker                                                            3.2.0             26m
97-master-generated-kubelet                        00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
97-worker-generated-kubelet                        00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
98-master-generated-kubelet                        00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
98-worker-generated-kubelet                        00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
99-iptables                                                                                   3.2.0             139m
99-master-generated-kubelet                        00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             26m
99-master-generated-registries                     00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
99-master-ssh                                                                                 3.2.0             139m
99-worker-generated-kubelet                        00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             26m
99-worker-generated-registries                     00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
99-worker-ssh                                                                                 3.2.0             139m
rendered-master-8f96bff76801cdb527b65caff9c289a5   00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
rendered-master-c68a892145e46db8f9df67d23c8b497d   00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             26m
rendered-worker-22d6eab1dc682be9bf38512201b615b8   00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             134m
rendered-worker-8b89ec9f6ba14d18e395890fa7afe0b4   00143af1a51bedf0290496a6a97e47cf60b18693   3.4.0             26m
[root@INBACRNRDL0102 ~]# oc get RuntimeClass
NAME                              HANDLER            AGE
common-runtime-class              high-performance   37m
performance-mno-wp-sched-master   high-performance   26m
performance-mno-wp-sched-worker   high-performance   26m
```
As you can observe, in the above output the `performance-mno-wp-sched-master` and `performance-mno-wp-sched-worker` it has been created.

- Creating the [performance-mno-wp-sched-master-pod.yaml](./performance-mno-wp-sched-master-pod.yaml) to the cluster:
```bash
[root@INBACRNRDL0102 ~]# oc create -f performance-mno-wp-sched-master-pod.yaml 
namespace/test-ns created
pod/test created
```

- Checking where has been the pod created:
```bash
[root@INBACRNRDL0102 ~]# oc get pods -n test-ns -o wide
NAME   READY   STATUS    RESTARTS   AGE   IP            NODE                               NOMINATED NODE   READINESS GATES
test   1/1     Running   0          15s   10.132.0.19   hub-ctlplane-2.5g-deployment.lab   <none>           <none>
```

Lets alter the [performance-mno-wp-sched-master-pod.yaml](./performance-mno-wp-sched-master-pod.yaml) to enforce the pod creation on `hub-worker-0.5g-deployment.lab` .

```yaml
---
# This YAML file defines a Namespace for the Pod
apiVersion: v1
kind: Namespace
metadata:
  name: test-ns
---
# This YAML file defines a Pod that uses the performance runtime class
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
  nodeName: hub-worker-0.5g-deployment.lab           # Pin to this specific node
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
Once the change has been apply to the cluster the following result its encountered:

```bash
[root@INBACRNRDL0102 ~]# oc create -f pod.yaml 
namespace/test-ns created
Warning: spec.nodeSelector[node-role.kubernetes.io/master]: use "node-role.kubernetes.io/control-plane" instead
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "main" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "main" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "main" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "main" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/test created
[root@INBACRNRDL0102 ~]# oc get pods -n test.ns
No resources found in test.ns namespace.
[root@INBACRNRDL0102 ~]# oc get pods -n test-ns
NAME   READY   STATUS                   RESTARTS   AGE
test   0/1     ContainerStatusUnknown   0          7s
[root@INBACRNRDL0102 ~]# oc get pods -n test-ns
NAME   READY   STATUS                   RESTARTS   AGE
test   0/1     ContainerStatusUnknown   0          9s
[root@INBACRNRDL0102 ~]# oc describe pods -n test-ns test
Name:                test
Namespace:           test-ns
Priority:            0
Runtime Class Name:  performance-mno-wp-sched-master
Service Account:     default
Node:                hub-worker-0.5g-deployment.lab/172.16.30.237
Start Time:          Tue, 24 Jun 2025 09:28:41 -0700
Labels:              <none>
Annotations:         cpu-load-balancing.crio.io: disable
                     cpu-quota.crio.io: disable
                     irq-load-balancing.crio.io: disable
                     k8s.ovn.org/pod-networks:
                       {"default":{"ip_addresses":["10.132.2.32/23"],"mac_address":"0a:58:0a:84:02:20","gateway_ips":["10.132.2.1"],"routes":[{"dest":"10.132.0.0...
                     openshift.io/scc: anyuid
Status:              Failed
Reason:              NodeAffinity
Message:             Pod was rejected: Predicate NodeAffinity failed: node(s) didn't match Pod's node affinity/selector
IP:                  
IPs:                 <none>
Containers:
  main:
    Container ID:  
    Image:         registry.access.redhat.com/ubi8-micro:latest
    Image ID:      
    Port:          <none>
    Host Port:     <none>
    Command:
      /bin/sh
      -c
      --
    Args:
      while true; do sleep 99999999; done;
    State:          Terminated
      Reason:       ContainerStatusUnknown
      Message:      The container could not be located when the pod was terminated
      Exit Code:    137
      Started:      Mon, 01 Jan 0001 00:00:00 +0000
      Finished:     Mon, 01 Jan 0001 00:00:00 +0000
    Ready:          False
    Restart Count:  0
    Limits:
      cpu:     4
      memory:  2Gi
    Requests:
      cpu:        4
      memory:     2Gi
    Environment:  <none>
    Mounts:
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-zdt8j (ro)
Conditions:
  Type                        Status
  PodReadyToStartContainers   False 
  Initialized                 True 
  Ready                       False 
  ContainersReady             False 
  PodScheduled                True 
Volumes:
  kube-api-access-zdt8j:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    ConfigMapOptional:       <nil>
    DownwardAPI:             true
    ConfigMapName:           openshift-service-ca.crt
    ConfigMapOptional:       <nil>
QoS Class:                   Guaranteed
Node-Selectors:              node-role.kubernetes.io/master=
Tolerations:                 node.kubernetes.io/memory-pressure:NoSchedule op=Exists
                             node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type     Reason        Age   From     Message
  ----     ------        ----  ----     -------
  Warning  NodeAffinity  21s   kubelet  Predicate NodeAffinity failed: node(s) didn't match Pod's node affinity/selector
```

- Changing the [performance-mno-wp-sched-master-pod.yaml](./performance-mno-wp-sched-master-pod.yaml) to [common-runtime-class-pod.yaml](./common-runtime-class-pod.yaml) to create the pods on masters and workers:
```bash
[root@INBACRNRDL0102 ~]# oc create -f common-runtime-class-pod.yaml 
namespace/test-ns created
pod/test created
```

- Checking where has been the pod created:

```bash
[root@INBACRNRDL0102 ~]# oc get pods -n test-ns -o wide
NAME   READY   STATUS    RESTARTS   AGE   IP            NODE                             NOMINATED NODE   READINESS GATES
test   1/1     Running   0          4s    10.132.2.36   hub-worker-0.5g-deployment.lab   <none>           <none>
```

Lets alter the [common-runtime-class-pod.yaml](./common-runtime-class-pod.yaml) to enforce the pod creation on `hub-ctlplane-1.5g-deployment.lab` .

```yaml
---
# This YAML file defines a Namespace for the Pod
apiVersion: v1
kind: Namespace
metadata:
  name: test-ns
---
# This YAML file defines a Pod that uses the performance runtime class
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
  runtimeClassName: common-runtime-class  # Map to the correct performance class
  nodeName: hub-ctlplane-1.5g-deployment.lab           # Pin to this specific node
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
Once the change has been apply to the cluster the following result its encountered:

```bash
[root@INBACRNRDL0102 ~]# oc get pods -n test-ns -o wide
NAME   READY   STATUS    RESTARTS   AGE   IP            NODE                               NOMINATED NODE   READINESS GATES
test   1/1     Running   0          8s    10.133.0.73   hub-ctlplane-1.5g-deployment.lab   <none>           <none>
```