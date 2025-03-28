# L1-CloudPlatform

The purpose of this repo its to document all the steps in deploying a CloudPlatform which purpose its to deploy, manage and monitor a number of Spoke(s) OCP Clusters.

> [!CAUTION]
> Unless specified otherwise, everything contained in this repository is unsupported by Red Hat.

## Table of Contents
- [L1-CloudPlatform](#l1-cloudplatform)
  - [Table of Contents](#table-of-contents)
  - [Method of Procedure](#method-of-procedure)
    - [Prerequisites](#prerequisites)
      - [High Level Diagram of the Hub Set-up:](#high-level-diagram-of-the-hub-set-up)
    - [Step 0. Download the pre-requisites binaries](#step-0-download-the-pre-requisites-binaries)
    - [Step 1. Mirorring the OCI content for a disconnected installation using oc-mirror](#step-1-mirorring-the-oci-content-for-a-disconnected-installation-using-oc-mirror)
    - [Step 2. Mirroring the OCI content to a AirGapped Registry](#step-2-mirroring-the-oci-content-to-a-airgapped-registry)
    - [Step 3. Downloading the RHCOS to AirGapped HTTP(s) Server](#step-3-downloading-the-rhcos-to-airgapped-https-server)
    - [Step 4. Agent-based Installer](#step-4-agent-based-installer)
    - [Step 5. Hub Configuration](#step-5-hub-configuration)
    - [Step 6. Spoke deployment](#step-6-spoke-deployment)
    - [Step 7. Hub Cluster Audit and Infra Logs Aggregation](#step-7-hub-cluster-audit-and-infra-logs-aggregation)
    - [Step 8. Hub Cluster Backup and Restore](#step-8-hub-cluster-backup-and-restore)
    - [Step 9. Hub Cluster Spoke's Observability](#step-9-hub-cluster-spokes-observability)
  - [Troubleshooting](#troubleshooting)
  - [Conclusions](#conclusions)
    - [ArgoCD application management:](#argocd-application-management)
    - [No OSD pods are running in an OCS 4.x cluster, even when the OSD Prepare pods are in Completed state, Why?](#no-osd-pods-are-running-in-an-ocs-4x-cluster-even-when-the-osd-prepare-pods-are-in-completed-state-why)
  - [Results and Problems](#results-and-problems)

## Method of Procedure

### [Prerequisites](https://docs.openshift.com/container-platform/4.16/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html)

In order to have a fully functional Hub Cluster and deploy Managed/Spoke(s) Clusters ensure your environment meets the following [prerequisites](https://docs.openshift.com/container-platform/4.16/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html):

- [AirGapped Registry](https://docs.openshift.com/container-platform/4.16/installing/disconnected_install/installing-mirroring-creating-registry.html)

_Download and install a local, minimal single instance deployment of Red Hat Quay to aid bootstrapping the first disconnected cluster. [Learn more](https://docs.openshift.com/container-platform/4.17/disconnected/mirroring/installing-mirroring-installation-images.html#installation-about-mirror-registry_installing-mirroring-installation-images)_

- AirGapped HTTP(s) Server

_Install a local, minimal single instance deployment of an http-server to aid bootstrapping the first Hub and for Managed/Spoke(s) Disconnected Cluster(s)._

- Git-Server

_Install a local, minimal single instance deployment of an git-server to aid the Hub day2-operators deployment + configuration and bootstrapping the Managed/Spoke(s) Disconnected Cluster(s)._

- DNS-Server

#### High Level Diagram of the Hub Set-up:

![HighLevelDiagram](./media/c__Users_idumi_OneDrive_Documents_GitHub_l1-cp_media_HighLevelDiagram.png)

### Step 0. Download the pre-requisites binaries

> [!WARNING]
> Ensure to properly configure your proxy in case of proxy usage for reaching domains like `quay.io` and or `registry.redhat.io`.
> Linux OS example:
> ```bash
> export https_proxy="https://proxy.server.com:PORT"
> export http_proxy="http://proxy.server.com:PORT"
> export no_proxy="localhost,127.0.0.1,::1"  # Addresses to bypass proxy
> ```
> In the above example, ensure to use your environment values! 

- Ensure my environment has `oc-mirror` client:
```bash
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.16.15/oc-mirror.tar.gz | tar -xz && chmod +x oc-mirror
```
Installing the [oc-mirror](https://docs.openshift.com/container-platform/4.16/installing/disconnected_install/installing-mirroring-disconnected.html#installing-mirroring-disconnected) OpenShift CLI plugin. 

- Ensure my environment has `oc` client:
```bash
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.16.15/openshift-client-linux-4.16.15.tar.gz && tar -xzf openshift-client-linux-4.16.15.tar.gz && chmod +x oc kubectl
```

### Step 1. Mirorring the OCI content for a [disconnected installation using oc-mirror](https://docs.openshift.com/container-platform/4.16/installing/disconnected_install/installing-mirroring-disconnected.html)

> [!WARNING]
> Ensure to include in your `config.json` the pull-secret of your AirGapped Registry and Red Hat public [pull-secret](https://console.redhat.com/openshift/install/pull-secret).

Once we have all the prerequisite met on the system, lets proceed in creating the [imageset-config.yml](./imageset-config.yml) file:

Example for `advanced-cluster-management`: 
```bash
# DOCKER_CONFIG=/root/.docker/; ./oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v4.16 --package=advanced-cluster-management

NAME                         DISPLAY NAME                                DEFAULT CHANNEL
advanced-cluster-management  Advanced Cluster Management for Kubernetes  release-2.12

PACKAGE                      CHANNEL       HEAD
advanced-cluster-management  release-2.10  advanced-cluster-management.v2.10.6
advanced-cluster-management  release-2.11  advanced-cluster-management.v2.11.3
advanced-cluster-management  release-2.12  advanced-cluster-management.v2.12.0
```
In order to validate all the day2-operators default channel version an example its provided in [process_packages.sh](./process_packages.sh), the script its producing the following output:

```bash
# ./process_packages.sh
Processing package: advanced-cluster-management
NAME                         DISPLAY NAME                                DEFAULT CHANNEL
advanced-cluster-management  Advanced Cluster Management for Kubernetes  release-2.12

PACKAGE                      CHANNEL       HEAD
advanced-cluster-management  release-2.10  advanced-cluster-management.v2.10.6
advanced-cluster-management  release-2.11  advanced-cluster-management.v2.11.3
advanced-cluster-management  release-2.12  advanced-cluster-management.v2.12.0
Processing package: multicluster-engine
NAME                 DISPLAY NAME                        DEFAULT CHANNEL
multicluster-engine  multicluster engine for Kubernetes  stable-2.7

PACKAGE              CHANNEL     HEAD
multicluster-engine  stable-2.5  multicluster-engine.v2.5.7
multicluster-engine  stable-2.6  multicluster-engine.v2.6.3
multicluster-engine  stable-2.7  multicluster-engine.v2.7.1
Processing package: topology-aware-lifecycle-manager
NAME                              DISPLAY NAME                      DEFAULT CHANNEL
topology-aware-lifecycle-manager  Topology Aware Lifecycle Manager  stable

PACKAGE                           CHANNEL  HEAD
topology-aware-lifecycle-manager  4.16     topology-aware-lifecycle-manager.v4.16.2
topology-aware-lifecycle-manager  stable   topology-aware-lifecycle-manager.v4.16.2
Processing package: openshift-gitops-operator
NAME                       DISPLAY NAME              DEFAULT CHANNEL
openshift-gitops-operator  Red Hat OpenShift GitOps  latest

PACKAGE                    CHANNEL      HEAD
openshift-gitops-operator  gitops-1.10  openshift-gitops-operator.v1.10.6
openshift-gitops-operator  gitops-1.11  openshift-gitops-operator.v1.11.7-0.1724840231.p
openshift-gitops-operator  gitops-1.12  openshift-gitops-operator.v1.12.6
openshift-gitops-operator  gitops-1.13  openshift-gitops-operator.v1.13.3
openshift-gitops-operator  gitops-1.14  openshift-gitops-operator.v1.14.2
openshift-gitops-operator  gitops-1.6   openshift-gitops-operator.v1.6.6
openshift-gitops-operator  gitops-1.7   openshift-gitops-operator.v1.7.4-0.1690486082.p
openshift-gitops-operator  gitops-1.8   openshift-gitops-operator.v1.8.6
openshift-gitops-operator  gitops-1.9   openshift-gitops-operator.v1.9.4
openshift-gitops-operator  latest       openshift-gitops-operator.v1.14.2
Processing package: odf-operator
NAME          DISPLAY NAME               DEFAULT CHANNEL
odf-operator  OpenShift Data Foundation  stable-4.16

PACKAGE       CHANNEL      HEAD
odf-operator  stable-4.15  odf-operator.v4.15.8-rhodf
odf-operator  stable-4.16  odf-operator.v4.16.3-rhodf
Processing package: ocs-operator
NAME          DISPLAY NAME                 DEFAULT CHANNEL
ocs-operator  OpenShift Container Storage  stable-4.16

PACKAGE       CHANNEL      HEAD
ocs-operator  stable-4.15  ocs-operator.v4.15.8-rhodf
ocs-operator  stable-4.16  ocs-operator.v4.16.3-rhodf
Processing package: odf-csi-addons-operator
NAME                     DISPLAY NAME  DEFAULT CHANNEL
odf-csi-addons-operator  CSI Addons    stable-4.16

PACKAGE                  CHANNEL      HEAD
odf-csi-addons-operator  stable-4.15  odf-csi-addons-operator.v4.15.8-rhodf
odf-csi-addons-operator  stable-4.16  odf-csi-addons-operator.v4.16.3-rhodf
Processing package: local-storage-operator
NAME                    DISPLAY NAME   DEFAULT CHANNEL
local-storage-operator  Local Storage  stable

PACKAGE                 CHANNEL  HEAD
local-storage-operator  stable   local-storage-operator.v4.16.0-202411190033
Processing package: mcg-operator
NAME          DISPLAY NAME     DEFAULT CHANNEL
mcg-operator  NooBaa Operator  stable-4.16

PACKAGE       CHANNEL      HEAD
mcg-operator  stable-4.15  mcg-operator.v4.15.8-rhodf
mcg-operator  stable-4.16  mcg-operator.v4.16.3-rhodf
Processing package: cluster-logging
NAME             DISPLAY NAME               DEFAULT CHANNEL
cluster-logging  Red Hat OpenShift Logging  stable-6.1

PACKAGE          CHANNEL     HEAD
cluster-logging  stable      cluster-logging.v5.9.9
cluster-logging  stable-5.8  cluster-logging.v5.8.15
cluster-logging  stable-5.9  cluster-logging.v5.9.9
cluster-logging  stable-6.0  cluster-logging.v6.0.2
cluster-logging  stable-6.1  cluster-logging.v6.1.0
Processing package: odf-prometheus-operator
NAME                     DISPLAY NAME         DEFAULT CHANNEL
odf-prometheus-operator  Prometheus Operator  stable-4.16

PACKAGE                  CHANNEL      HEAD
odf-prometheus-operator  stable-4.16  odf-prometheus-operator.v4.16.3-rhodf
Processing package: recipe
NAME    DISPLAY NAME  DEFAULT CHANNEL
recipe  Recipe        stable-4.16

PACKAGE  CHANNEL      HEAD
recipe   stable-4.16  recipe.v4.16.3-rhodf
Processing package: rook-ceph-operator
NAME                DISPLAY NAME  DEFAULT CHANNEL
rook-ceph-operator  Rook-Ceph     stable-4.16

PACKAGE             CHANNEL      HEAD
rook-ceph-operator  stable-4.16  rook-ceph-operator.v4.16.3-rhodf
All packages processed.
```
Utilize the values obtained during the `day2-operator` package inspection to verify that the `DEFAULT CHANNEL` is correctly templated in the [imageset-config.yml](./imageset-config.yml) file. Once validated, proceed with the mirroring process:

```bash
# DOCKER_CONFIG=${HOME}/.docker/config.json; ./oc-mirror --config imageset-config.yml file:///apps/idumi/
Creating directory: home/oc-mirror-workspace/src/publish
Creating directory: home/oc-mirror-workspace/src/v2
Creating directory: home/oc-mirror-workspace/src/charts
Creating directory: home/oc-mirror-workspace/src/release-signatures
backend is not configured in imageset-config.yaml, using stateless mode
backend is not configured in imageset-config.yaml, using stateless mode
No metadata detected, creating new workspace
..redacted..
info: Mirroring completed in 2h3m21.48s (9.416MB/s)
Creating archive /apps/idumi/mirror_seq1_000000.tar
Creating archive /apps/idumi/mirror_seq1_000001.tar
Creating archive /apps/idumi/mirror_seq1_000002.tar
Creating archive /apps/idumi/mirror_seq1_000003.tar
Creating archive /apps/idumi/mirror_seq1_000004.tar
Creating archive /apps/idumi/mirror_seq1_000005.tar
Creating archive /apps/idumi/mirror_seq1_000006.tar
Creating archive /apps/idumi/mirror_seq1_000007.tar
Creating archive /apps/idumi/mirror_seq1_000008.tar
Creating archive /apps/idumi/mirror_seq1_000009.tar
Creating archive /apps/idumi/mirror_seq1_000010.tar
Creating archive /apps/idumi/mirror_seq1_000011.tar
Creating archive /apps/idumi/mirror_seq1_000012.tar
Creating archive /apps/idumi/mirror_seq1_000013.tar
Creating archive /apps/idumi/mirror_seq1_000014.tar
Creating archive /apps/idumi/mirror_seq1_000015.tar
Creating archive /apps/idumi/mirror_seq1_000016.tar
Creating archive /apps/idumi/mirror_seq1_000017.tar
```
> [!WARNING]
> The message `info: Mirroring completed in 2h3m21.48s (9.416MB/s)` is provided as an illustrative example and should not be interpreted as a definitive benchmark. Actual performance may vary depending on factors such as internet broadband speed, network latency, disk performance, and other environmental conditions.

The full mirroring logs can be reffer at [.oc-mirror.log](./.oc-mirror.log)
Once the mirroring process has ended, the following content has been created:
```bash
# ls -lh /apps/idumi/
total 68G
-rw-r--r-- 1 root root 3.8G Nov 30 13:36 mirror_seq1_000000.tar
-rw-r--r-- 1 root root 4.0G Nov 30 13:37 mirror_seq1_000001.tar
-rw-r--r-- 1 root root 4.0G Nov 30 13:40 mirror_seq1_000002.tar
-rw-r--r-- 1 root root 4.0G Nov 30 13:42 mirror_seq1_000003.tar
-rw-r--r-- 1 root root 4.0G Nov 30 13:44 mirror_seq1_000004.tar
-rw-r--r-- 1 root root 3.7G Nov 30 13:46 mirror_seq1_000005.tar
-rw-r--r-- 1 root root 4.0G Nov 30 13:49 mirror_seq1_000006.tar
-rw-r--r-- 1 root root 4.0G Nov 30 13:52 mirror_seq1_000007.tar
-rw-r--r-- 1 root root 4.0G Nov 30 13:55 mirror_seq1_000008.tar
-rw-r--r-- 1 root root 4.0G Nov 30 13:59 mirror_seq1_000009.tar
-rw-r--r-- 1 root root 4.0G Nov 30 14:02 mirror_seq1_000010.tar
-rw-r--r-- 1 root root 4.0G Nov 30 14:05 mirror_seq1_000011.tar
-rw-r--r-- 1 root root 4.0G Nov 30 14:07 mirror_seq1_000012.tar
-rw-r--r-- 1 root root 4.0G Nov 30 14:10 mirror_seq1_000013.tar
-rw-r--r-- 1 root root 4.0G Nov 30 14:13 mirror_seq1_000014.tar
-rw-r--r-- 1 root root 4.0G Nov 30 14:16 mirror_seq1_000015.tar
-rw-r--r-- 1 root root 4.0G Nov 30 14:19 mirror_seq1_000016.tar
-rw-r--r-- 1 root root  83M Nov 30 14:19 mirror_seq1_000017.tar
drwxr-xr-x 3 root root 4.0K Nov 30 11:30 oc-mirror-workspace
```

For any reference of the [imageset-config.yml](./imageset-config.yml).

> [!WARNING]
> In order to ensure that we adhere to the latest `day2-operator` channel used, ensure that your `imageset-config.yaml` content its allign the content reflected by running:
>
> ```bash
> oc-mirror list operators --catalog=registry.redhat.io/redhat/redhat-operator-index:v4.16 --package=advanced-cluster-management
> Logging to .oc-mirror.log
> NAME                         DISPLAY NAME                                DEFAULT CHANNEL
> advanced-cluster-management  Advanced Cluster Management for Kubernetes  release-2.12
> 
> PACKAGE                      CHANNEL       HEAD
> advanced-cluster-management  release-2.10  advanced-cluster-management.v2.10.6
> advanced-cluster-management  release-2.11  advanced-cluster-management.v2.11.3
> advanced-cluster-management  release-2.12  advanced-cluster-management.v2.12.0
> ```
> As outlined in the above example, the [imageset-config.yml](./imageset-config.yml) used in week46-2024 it was refering the `release-2.11` default channel for the `advanced-cluster-management`, in order to adhere to the latest changes, use the [imageset-config-w47.yml](./imageset-config-w47.yml).


### Step 2. Mirroring the OCI content to a AirGapped Registry

Based on the `.tar` files generated in the previous step, we will now outline the procedure required to mirror the content to an air-gapped registry, as demonstrated in the following example:
```bash
# DOCKER_CONFIG=${HOME}/.docker/config.json;  \
    ./oc-mirror --from=./apps/idumi/ docker://registry.example:5000 
```

To provide a detailed illustration of the process, we will reference the following AirGapped Registry: `infra.5g-deployment.lab:8443`. The contents of this registry are outlined below:

```bash
# curl -X GET -u admin:raspberry https://infra.5g-deployment.lab:8443/v2/_catalog --insecure | jq .
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100    20  100    20    0     0    152      0 --:--:-- --:--:-- --:--:--   152
{
  "repositories": []
}
```

As outline above the AirGapped Registry its empty, starting the mirroring from the `.tar` file(s) to the AirGapped Registry:

```bash
 # DOCKER_CONFIG=${HOME}/.docker/config.json; ./oc-mirror --from=/apps/idumi/ docker://infra.5g-deployment.lab:8443/l1-cp
Checking push permissions for infra.5g-deployment.lab:8443
Publishing image set from archive "/apps/idumi/" to registry "infra.5g-deployment.lab:8443"
..redacted..
info: Planning completed in 10ms
uploading: infra.5g-deployment.lab:8443/l1-cp/openshift/release sha256:84126cf41de41b2dd11560aada5c79cb9a55fb5c91929b5685bc129121cc9301 24.95KiB
uploading: infra.5g-deployment.lab:8443/l1-cp/openshift/release sha256:781837ff0f7c938dca851957050ee20b75813a82d87e92a4f6fdac8efa5e799b 327.9MiB
sha256:a2e18a2dd3d2dac63f06a5775f082bdd1c2bd360a5173bef2e08a974832a04fa infra.5g-deployment.lab:8443/l1-cp/openshift/release:4.16.15-x86_64-agent-installer-api-server
info: Mirroring completed in 10.89s (31.56MB/s)
Wrote release signatures to oc-mirror-workspace/results-1732973958
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/include-config.gob
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/index/index.json
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/045d7948b63e2d84f9e5548232898905900f2be572e8970e0d1991179efd6c73
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/0fe3a205d2d8f036e2b1e1d50d10c4c3537cc2ba8f3f4a3e43d952358dfc22c6
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/129afbc56d6c83f9d3eacc90ee800ea03bc146145affcd16327d2b08a7600910
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/209ada9ff01f0bf1048c543af20a04764ba772ae8104eceb4cdd0d20eb98963a
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/229d90090e889dcdd32709d2f6628f13f139436e2e8cb9bdaf75858e39be22c5
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/35e4749f4cfb8cebcf039ad81f0716b7ab14f56cb7d529be452e04b99b6a7968
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/36489ff863648fd4898ae5297bff9ff47492bcde2ee85face77af37ce67c013d
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/38e753e5cb9360955b30410172d735a0a410f6106aa75ab14cae94bbbdc0bb41
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/45c5063cd74e2470c823ccc90f6e0f674d58673a855264faa6140d1f176b1b2f
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/4c1db222f00d2dc5398975427c640d1dcd01637fa8e449f8a1ceed811f23ec2e
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/52c29b8da622cfd57d1149eb0412d839d2faeb6935f5a361ee1405ef9d698d5a
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/545dc39de9d4cb017d563a4c16706add7f7e98a025aa8bea0d9439072bac0ef7
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/56c1e812f51f0e0a3e5d8759584a0da13604839e8c5941ff694ca61928ceedc9
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/6c9198eeea467f59d150b1fd553f1276338f09cf974719635b07c74962f4540c
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/6dc2ad2bc4e6e1396d7796ad71946955cd4adca263d3aeafb7fcc9fb3f75721f
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/771989c1f0baf2cdd5765e7078b31867daa242b18a311f2e11da1323b2a6b8fd
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/7a7842534d9ed2a95ea1ed40c1414c63b4424384c91d1f4b55bafee7e4f134eb
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/846e7d78a49474ba894609edcdac9ede80da3a4192637ca64d9f6065332e9267
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/919ae6d903c8fa1cfce3a4bfc8ec05cb974ee6003a01ebe6c61eb86dff65cd6d
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/92123690d207b7aebf26528b24e9f046fc6b2e0894369dba143b5255980879c9
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/a86d822494a2039dd151cbec25e9648384fa5ec173948793a496b6d683be23e8
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/ae0badd537673e93bcbcf384ce6acda3cdfef75d43bd2f7bc766ef5ffba3e51a
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/bc254f73ff381207aa1947298b09bdd264aa4e2e2ea2c3d14547269825a04720
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/cce32ddbadbc53ae62d9dab4a4d826d19ceb12eb5a425e2ead149f2999a8a589
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/de8028df1e6bc94a4a00e2815ab52eb3f1f76dc8819bc6bdc7c3fdd4485f5fc7
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/e204c2423a2d004dce141e310c51e0fe2b4b0510daac18c342faf3e0782051a6
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/f7fb3a4ecfa2bf89c492c78ac4e0c108e099152ff074ece5ddd1ffe1ee1d21f5
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/blobs/sha256/fc7937896fdcdf126302a9dcb481bcbe091a13e65b1cb3ba137fce459c92e8d6
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/index.json
catalogs/registry.redhat.io/redhat/redhat-operator-index/v4.16/layout/oci-layout
Rendering catalog image "infra.5g-deployment.lab:8443/l1-cp/redhat/redhat-operator-index:v4.16" with file-based catalog
Writing image mapping to oc-mirror-workspace/results-1732973958/mapping.txt
Writing UpdateService manifests to oc-mirror-workspace/results-1732973958
Writing CatalogSource manifests to oc-mirror-workspace/results-1732973958
Writing ICSP manifests to oc-mirror-workspace/results-1732973958
```
> [!WARNING]
> To ensure proper configuration, it is essential to maintain the  mirrored directory `oc-mirror-workspace/results-1732973958/` and its  associated files, `catalogSource-cs-redhat-operator-index.yaml` and  `imageContentSourcePolicy.yaml`, as they are referenced in the [install-config.yaml](./workingdir/install-config.yaml). The specified  files must be stored under the [openshift](./workingdir/openshift/) directory. 
> 
> Additionally, the contents of `imageContentSourcePolicy.yaml` are required to be properly incorporated into `install-config.yaml` as follows:
> 
> ```yaml
> ---
> ..redacted..
>   repositoryDigestMirrors:
>   - mirrors:
>     - infra.5g-deployment.lab:8443/l1-cp/openshift/release
>     source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
>   - mirrors:
>     - infra.5g-deployment.lab:8443/l1-cp/openshift/release-images
>     source: quay.io/openshift-release-dev/ocp-release
> ```
> Ensure that these configurations are correctly placed and updated to support the deployment process effectively.

Building on the previous example, we will proceed to validate the contents of the AirGapped Registry upon completion of the mirroring process:

```bash
# curl -X GET -u admin:raspberry https://infra.5g-deployment.lab:8443/v2/_catalog --insecure | jq .
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  4732    0  4732    0     0  26288      0 --:--:-- --:--:-- --:--:-- 26143
{
  "repositories": [
    "l1-cp/multicluster-engine/addon-manager-rhel9",
    "l1-cp/multicluster-engine/assisted-image-service-rhel9",
    "l1-cp/multicluster-engine/assisted-installer-agent-rhel9",
    "l1-cp/multicluster-engine/assisted-installer-controller-rhel9",
    "l1-cp/multicluster-engine/assisted-installer-rhel9",
    "l1-cp/multicluster-engine/assisted-service-8-rhel8",
    "l1-cp/multicluster-engine/assisted-service-9-rhel9",
    "l1-cp/multicluster-engine/backplane-rhel9-operator",
    "l1-cp/multicluster-engine/cluster-api-provider-agent-rhel9",
    "l1-cp/multicluster-engine/cluster-api-provider-kubevirt-rhel9",
    "l1-cp/multicluster-engine/cluster-api-rhel9",
    "l1-cp/multicluster-engine/cluster-curator-controller-rhel9",
    "l1-cp/multicluster-engine/cluster-image-set-controller-rhel9",
    "l1-cp/multicluster-engine/cluster-proxy-addon-rhel9",
    "l1-cp/multicluster-engine/cluster-proxy-rhel9",
    "l1-cp/multicluster-engine/clusterclaims-controller-rhel9",
    "l1-cp/multicluster-engine/clusterlifecycle-state-metrics-rhel9",
    "l1-cp/multicluster-engine/console-mce-rhel9",
    "l1-cp/multicluster-engine/discovery-rhel9",
    "l1-cp/multicluster-engine/hive-rhel9",
    "l1-cp/multicluster-engine/hypershift-addon-rhel9-operator",
    "l1-cp/multicluster-engine/hypershift-cli-rhel9",
    "l1-cp/multicluster-engine/hypershift-rhel9-operator",
    "l1-cp/multicluster-engine/image-based-install-rhel9",
    "l1-cp/multicluster-engine/kube-rbac-proxy-mce-rhel9",
    "l1-cp/multicluster-engine/managed-serviceaccount-rhel9",
    "l1-cp/multicluster-engine/managedcluster-import-controller-rhel9",
    "l1-cp/multicluster-engine/mce-operator-bundle",
    "l1-cp/multicluster-engine/multicloud-manager-rhel9",
    "l1-cp/multicluster-engine/must-gather-rhel9",
    "l1-cp/multicluster-engine/placement-rhel9",
    "l1-cp/multicluster-engine/provider-credential-controller-rhel9",
    "l1-cp/multicluster-engine/registration-operator-rhel9",
    "l1-cp/multicluster-engine/registration-rhel9",
    "l1-cp/multicluster-engine/work-rhel9",
    "l1-cp/odf4/cephcsi-rhel9",
    "l1-cp/odf4/mcg-core-rhel9",
    "l1-cp/odf4/mcg-operator-bundle",
    "l1-cp/odf4/mcg-rhel9-operator",
    "l1-cp/odf4/ocs-client-console-rhel9",
    "l1-cp/odf4/ocs-client-operator-bundle",
    "l1-cp/odf4/ocs-client-rhel9-operator",
    "l1-cp/odf4/ocs-metrics-exporter-rhel9",
    "l1-cp/odf4/ocs-operator-bundle",
    "l1-cp/odf4/ocs-rhel9-operator",
    "l1-cp/odf4/odf-console-rhel9",
    "l1-cp/odf4/odf-cosi-sidecar-rhel9",
    "l1-cp/odf4/odf-csi-addons-operator-bundle",
    "l1-cp/odf4/odf-csi-addons-rhel9-operator",
    "l1-cp/odf4/odf-csi-addons-sidecar-rhel9",
    "l1-cp/odf4/odf-must-gather-rhel9",
    "l1-cp/odf4/odf-operator-bundle",
    "l1-cp/odf4/odf-prometheus-operator-bundle",
    "l1-cp/odf4/odf-rhel9-operator",
    "l1-cp/odf4/odr-recipe-operator-bundle",
    "l1-cp/odf4/odr-rhel9-operator",
    "l1-cp/odf4/rook-ceph-operator-bundle",
    "l1-cp/odf4/rook-ceph-rhel9-operator",
    "l1-cp/openshift/graph-image",
    "l1-cp/openshift/release",
    "l1-cp/openshift/release-images",
    "l1-cp/openshift-gitops-1/argo-rollouts-rhel8",
    "l1-cp/openshift-gitops-1/argocd-rhel8",
    "l1-cp/openshift-gitops-1/console-plugin-rhel8",
    "l1-cp/openshift-gitops-1/dex-rhel8",
    "l1-cp/openshift-gitops-1/gitops-operator-bundle",
    "l1-cp/openshift-gitops-1/gitops-rhel8",
    "l1-cp/openshift-gitops-1/gitops-rhel8-operator",
    "l1-cp/openshift-gitops-1/kam-delivery-rhel8",
    "l1-cp/openshift-gitops-1/must-gather-rhel8",
    "l1-cp/openshift-logging/cluster-logging-operator-bundle",
    "l1-cp/openshift-logging/cluster-logging-rhel9-operator",
    "l1-cp/openshift-logging/log-file-metric-exporter-rhel9",
    "l1-cp/openshift-logging/vector-rhel9",
    "l1-cp/openshift4/ose-configmap-reloader-rhel9",
    "l1-cp/openshift4/ose-csi-external-attacher-rhel8",
    "l1-cp/openshift4/ose-csi-external-attacher-rhel9",
    "l1-cp/openshift4/ose-csi-external-provisioner",
    "l1-cp/openshift4/ose-csi-external-provisioner-rhel9",
    "l1-cp/openshift4/ose-csi-external-resizer",
    "l1-cp/openshift4/ose-csi-external-resizer-rhel9",
    "l1-cp/openshift4/ose-csi-external-snapshotter-rhel8",
    "l1-cp/openshift4/ose-csi-external-snapshotter-rhel9",
    "l1-cp/openshift4/ose-csi-node-driver-registrar",
    "l1-cp/openshift4/ose-csi-node-driver-registrar-rhel9",
    "l1-cp/openshift4/ose-haproxy-router",
    "l1-cp/openshift4/ose-kube-rbac-proxy",
    "l1-cp/openshift4/ose-kube-rbac-proxy-rhel9",
    "l1-cp/openshift4/ose-local-storage-diskmaker-rhel9",
    "l1-cp/openshift4/ose-local-storage-mustgather-rhel9",
    "l1-cp/openshift4/ose-local-storage-operator-bundle",
    "l1-cp/openshift4/ose-local-storage-rhel9-operator",
    "l1-cp/openshift4/ose-oauth-proxy",
    "l1-cp/openshift4/ose-oauth-proxy-rhel9",
    "l1-cp/openshift4/ose-prometheus-alertmanager-rhel9",
    "l1-cp/openshift4/ose-prometheus-config-reloader-rhel9",
    "l1-cp/openshift4/ose-prometheus-rhel9",
    "l1-cp/openshift4/ose-prometheus-rhel9-operator",
    "l1-cp/openshift4/topology-aware-lifecycle-manager-aztp-rhel9",
    "l1-cp/openshift4/topology-aware-lifecycle-manager-operator-bundle"
  ]
}
```

The following table privides an overview of the ammount of disk space required for the AirGapped Registry + a 10% overhead when mirroring the [imageset-config.yaml](./imageset-config.yml) :

| Version | Storage Required | Notes |
| --- | --- | --- |
| Cluster Release Operators 4.16.15 | ~ 20 GiB  | A single Release  |
| RHACM day2-operators | ~ 50 GiB | A single Release of RHACM Day2 Operators [imageset-config.yml](./imageset-config.yml)
| Additional troubleshooting OCI(s)| ~ 4 GiB | A single Release | 
| **Total**| **74 GiB** | 

The following table privides an overview of the ammount of disk space required for the AirGapped Registry + a 10% overhead when mirroring the [imageset-config-w47-versions.yml](./imageset-config-w47-versions.yml) :

| Version | Storage Required | Notes |
| --- | --- | --- |
| Cluster Release Operators 4.16.15 | ~ 20 GiB  | A single Release  |
| RHACM day2-operators | ~ 47 GiB | A single version of RHACM Day2 Operators [imageset-config-w47-versions.yml](./imageset-config-w47-versions.yml)
| Additional troubleshooting OCI(s)| ~ 4 GiB | A single Release | 
| **Total**| **71 GiB** | 

### Step 3. Downloading the RHCOS to AirGapped HTTP(s) Server

The [rhcos sources for deploying Managed/Spoke(s) 4.16 Clusters](https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.16/4.16.3/) its 

Ensure that you are downloading the following content:
- [rhcos-4.16.0-x86_64-live-rootfs.x86_64.img](https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.16/4.16.3/rhcos-4.16.3-x86_64-live-rootfs.x86_64.img)
- [rhcos-4.16.0-x86_64-live.x86_64.iso](https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.16/4.16.3/rhcos-4.16.3-x86_64-live.x86_64.iso)

And store them to your AirGapped HTTP(s) Server, this content its required while configuring [multicluster-engine](./hub-config/operators-config/01_ai_config.yaml) operator.


### Step 4. [Agent-based Installer](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html-single/installing_an_on-premise_cluster_with_the_agent-based_installer/index#about-the-agent-based-installer)


- Generating the `oc` client:

```bash
# ./oc adm release extract -a .docker/config.json \
     --command=oc registry.example:5000/ocp-release:4.16.15-x86_64 
```

- Generating the `openshift-install` client:

```bash
# ./oc adm release extract -a .docker/config.json \
     --command=openshift-install registry.example:5000/ocp-release:4.16.15-x86_64  
```
> [!WARNING]
> **Usage:**
>  - `--idms-file=''`, this specifies the path to an `ImageDigestMirrorSet` file. If provided, the data in this file will be used to locate alternative image sources.
>  - Additionally, the `--certificate-authority=''` flag is **optional** if the AirGapped Registry is already saved to the workstation.

- Generating the [workingdir](./workingdir/) directory structure:

```bash
# mkdir -p ${HOME}/workingdir
# tree ${HOME}/workingdir
.
├── agent-config.yaml
├── install-config.yaml
└── openshift
    ├── 99-masters-chrony-configuration.yaml
    ├── 99_01_argo.yaml
    ├── catalogSource-cs-redhat-operator-index.yaml
    ├── disable-operatorhub.yaml
    └── imageContentSourcePolicy.yaml

2 directories, 7 files
```

> [!NOTE]
> Ensure to include in your `openshift` directory the `98-var-lib-etcd.yaml` with the purpose of allocating the [etcd database](https://docs.openshift.com/container-platform/4.16/scalability_and_performance/recommended-performance-scale-practices/recommended-etcd-practices.html#move-etcd-different-disk_recommended-etcd-practices) to a dedicated partition in order to avoid performance issues with the cluster.

Explaining all the parameters of the [install-config.yaml](./workingdir/install-config.yaml), you can use the following approach:
```bash
# ./openshift-install explain installconfig.platform.baremetal
KIND:     InstallConfig
VERSION:  v1

RESOURCE: <object>
  BareMetal is the configuration used when installing on bare metal.

FIELDS:
    apiVIP <string>
      Format: ip
      DeprecatedAPIVIP is the VIP to use for internal API communication Deprecated: Use APIVIPs

    apiVIPs <[]string>
      Format: ip
      APIVIPs contains the VIP(s) to use for internal API communication. In dual stack clusters it contains an IPv4 and IPv6 address, otherwise only one VIP

    bootstrapExternalStaticGateway <string>
      Format: ip
      BootstrapExternalStaticGateway is the static network gateway of the bootstrap node. This can be useful in environments without a DHCP server.

    bootstrapExternalStaticIP <string>
      Format: ip
      BootstrapExternalStaticIP is the static IP address of the bootstrap node. This can be useful in environments without a DHCP server.

    bootstrapOSImage <string>
      BootstrapOSImage is a URL to override the default OS image for the bootstrap node. The URL must contain a sha256 hash of the image e.g https://mirror.example.com/images/qemu.qcow2.gz?sha256=a07bd...

    bootstrapProvisioningIP <string>
      Format: ip
      BootstrapProvisioningIP is the IP used on the bootstrap VM to bring up provisioning services that are used to create the control-plane machines

    clusterOSImage <string>
      ClusterOSImage is a URL to override the default OS image for cluster nodes. The URL must contain a sha256 hash of the image e.g https://mirror.example.com/images/metal.qcow2.gz?sha256=3b5a8...

    clusterProvisioningIP <string>
      ClusterProvisioningIP is the IP on the dedicated provisioning network where the baremetal-operator pod runs provisioning services, and an http server to cache some downloaded content e.g RHCOS/IPA images

    defaultMachinePlatform <object>
      DefaultMachinePlatform is the default configuration used when installing on bare metal for machine pools which do not define their own platform configuration.

    externalBridge <string>
      External bridge is used for external communication.

    externalMACAddress <string>
      ExternalMACAddress is used to allow setting a static unicast MAC address for the bootstrap host on the external network. Consider using the QEMU vendor prefix `52:54:00`. If left blank, libvirt will generate one for you.

    hosts <[]object> -required-
      Hosts is the information needed to create the objects in Ironic.
      Host stores all the configuration data for a baremetal host.

    ingressVIP <string>
      Format: ip
      DeprecatedIngressVIP is the VIP to use for ingress traffic Deprecated: Use IngressVIPs

    ingressVIPs <[]string>
      Format: ip
      IngressVIPs contains the VIP(s) to use for ingress traffic. In dual stack clusters it contains an IPv4 and IPv6 address, otherwise only one VIP

    libvirtURI <string>
      Default: "qemu:///system"
      LibvirtURI is the identifier for the libvirtd connection.  It must be reachable from the host where the installer is run. Default is qemu:///system

    provisioningBridge <string>
      Provisioning bridge is used for provisioning nodes, on the host that will run the bootstrap VM.

    provisioningDHCPExternal <boolean>
      DeprecatedProvisioningDHCPExternal indicates that DHCP is provided by an external service. This parameter is replaced by ProvisioningNetwork being set to "Unmanaged".

    provisioningDHCPRange <string>
      ProvisioningDHCPRange is used to provide DHCP services to hosts for provisioning.

    provisioningHostIP <string>
      DeprecatedProvisioningHostIP is the deprecated version of clusterProvisioningIP. When the baremetal platform was initially added to the installer, the JSON field for ClusterProvisioningIP was incorrectly set to "provisioningHostIP."  This field is here to allow backwards-compatibility.

    provisioningMACAddress <string>
      ProvisioningMACAddress is used to allow setting a static unicast MAC address for the bootstrap host on the provisioning network. Consider using the QEMU vendor prefix `52:54:00`. If left blank, libvirt will generate one for you.

    provisioningNetwork <string>
      Default: "Managed"
      Valid Values: "","Managed","Unmanaged","Disabled"
      ProvisioningNetwork is used to indicate if we will have a provisioning network, and how it will be managed.

    provisioningNetworkCIDR <Any>
      ProvisioningNetworkCIDR defines the network to use for provisioning.

    provisioningNetworkInterface <string>
      ProvisioningNetworkInterface is the name of the network interface on a control plane baremetal host that is connected to the provisioning network.
```

- Installing the [nmstatectl](https://docs.openshift.com/container-platform/4.16/installing/installing_with_agent_based_installer/installing-with-agent-based-installer.html#installing-ocp-agent-inputs_installing-with-agent-based-installer) on the host:
```bash
# dnf install /usr/bin/nmstatectl -y
```
- Generating the `.iso` content:

> [!WARNING]
> Ensure at this stage to create a local back-up of your `workingdir/`. This is important in case of any required troubleshooting because the `openshift-install agent create image` will "consume" the files to generate the *agent.x86_64.iso* .
> 
```bash
# ./openshift-install agent create image --dir ${HOME}/workingdir/. --log-level debug
```
Once the `agent.x86_64.iso` file has been generated, mount it to the Server(s) BMC and boot from it.

```bash
$ tree .
.
├── agent.x86_64.iso
├── auth
│   ├── kubeadmin-password
│   └── kubeconfig
├── oc                  # (optional: This binary can be also store under /usr/local/bin/)
├── openshift-install   # (optional: This binary can be also store under /usr/local/bin/)
└── rendezvousIP

1 directory, 6 files
```
> [!WARNING]
> Ensure at this stage to NOT remove the `./auth/{kubeadmin-password, kubeconfig}` because this will prevent the administrator to access the cluster.
>

- [Monitoring the installation process](https://docs.openshift.com/container-platform/4.16/installing/installing_with_agent_based_installer/installing-with-agent-based-installer.html#installing-ocp-agent-verify_installing-with-agent-based-installer):
```bash
./openshift-install --dir ${HOME}/workingdir/. agent wait-for install-complete \
    --log-level=info
```
### Step 5. [Hub Configuration](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.12/html-single/argo_cd_applications/index)

Once the Hub Cluster OCP and `openshift-gitop-operator` are fully deploy, you can proceed by creating the Hub Configuration ArgoCD Applications:

- To install support for ZTP-related CRs inside ArgoCD we need to patch the ArgoCD application with customized image:

```bash
# oc patch argocd openshift-gitops -n openshift-gitops --type=merge --patch-file ./hub-config/argocd/argocdpatch.json
 ```

- Label the Storage nodes of your Hub Cluster:
```bash
# oc label nodes master{0,1,2} cluster.ocs.openshift.io/openshift-storage=""
```
[Each worker node that has local storage devices to be used by OpenShift Container Storage must have a specific label to deploy OpenShift Container Storage pods.](https://docs.redhat.com/en/documentation/red_hat_openshift_container_storage/4.4/html-single/deploying_openshift_container_storage/index#requirements-for-installing-openshift-container-storage-using-local-storage-devices_aws-vmware)

- Login to the GitOps Operator:
```bash
# ARGOCD_PASS=$(oc get secret -n openshift-gitops openshift-gitops-cluster -o jsonpath='{.data.admin\.password}' | base64 --decode)
# ARGOCD_ROUTE=$(oc get routes -n openshift-gitops -o jsonpath='{.items[?(@.metadata.name=="openshift-gitops-server")].spec.host}')
# echo $ARGOCD_PASS
fAktrva8iwMBNFg9Wy5o4lnDHQs2zCZb
# argocd login $ARGOCD_ROUTE
WARNING: server certificate had error: tls: failed to verify certificate: x509: certificate signed by unknown authority. Proceed insecurely (y/n)? y
WARN[0003] Failed to invoke grpc call. Use flag --grpc-web in grpc calls. To avoid this warning message, use flag --grpc-web.
Username: admin
Password:
'admin:login' logged in successfully
Context 'openshift-gitops-server-openshift-gitops.apps.hub.5g-deployment.lab' updated
```

- [Add the Git reporsitory](https://argo-cd.readthedocs.io/en/latest/user-guide/commands/argocd_repo_add/#argocd-repo-add-command-reference) to the `openshift-gitops` operator:
```bash
  # Add a Git repository via SSH using a private key for authentication, ignoring the server's host key:
  argocd repo add git@git.example.com:repos/repo --insecure-ignore-host-key --ssh-private-key-path ~/id_rsa

  # Add a Git repository via SSH on a non-default port - need to use ssh:// style URLs here
  argocd repo add ssh://git@git.example.com:2222/repos/repo --ssh-private-key-path ~/id_rsa
```
More information about [Setting up an Argo CD instance](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.14/html/argo_cd_instance/setting-up-argocd-instance)

> [!WARNING]
> **Ensure that the Git server in use contains the necessary [hub-config](./hub-config/) directory**  
> The `hub-config` directory holds critical configuration files required for setting up and managing the target environment. It is crucial that the Git server > hosting these configurations reflects the exact environment version you plan to install.
> 
> ### Steps to Ensure Proper Setup:
> 1. **Clone the [hub-config](./hub-config/) Directory**:  
>    Begin by cloning the [hub-config](./hub-config/) directory from its original source (e.g., a central repository or template) to your Git server.
> 
> 2. **Customize the Configurations**:  
>    - Review the content of the [hub-config](./hub-config/) directory files and ensure that it aligns with the target version and environment-specific parameters you intend to deploy.
>    - Update any environment variables, versions, or deployment-specific configurations to match your desired setup.
>       - Ensure that the [argopatch.json](./hub-config/argocd/argopatch.json):
>         ```json
> 	        "image": "registry.example:443/ocp4-release/openshift4/ztp-site-generate-rhel8:v4.16"
>         ```
>         Reflects your environment, version and AirGapped Registry FQDN, namespace convention, etc.
>       - When customizing the [operators-deployment](./hub-config/operators-deployment/) it is critical to validate that the Subscription Custom Resource (CR) includes a `spec.source` field with the correct naming. Specifically, the value `cs-redhat-operator-index` must match the name used during the ABI deployment of the hub cluster.
>       - When customizing the [operators-config](./hub-config/operators-config/) it is critical to ensure that the following files reflect the environment:
>           - [00_rhacm_config.yaml](./hub-config/operators-config/00_rhacm_config.yaml): 
>             ```yaml
>             installer.open-cluster-management.io/mce-subscription-spec: '{"source": "cs-redhat-operator-index"}'
>             ```
>             The value `cs-redhat-operator-index` must match the name used during the ABI deployment of the hub cluster and the one mentioned  for the `mce-operator` subscription.
>           - [01_ai_config.yaml](./hub-config/operators-config/01_ai_config.yaml): 
>               - [custom-registries](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/clusters/cluster_mce_overview#mce_and_agent) ConfigMap CR which where:  
>                            - `data.ca-bundle.crt` includes the AirGapped Registry certificates
>                            - `data.registries.conf` includes the data which its stored under the hub `/etc/containers/registries.conf`
>          - The files [01_ai_config.yaml](./hub-config/operators-config/01_ai_config.yaml) and [02_ai_config.yaml](./hub-config/operators-config/02_ai_config.yaml) are designed to define the configuration for the Assisted Installer (AI) component, specifically addressing the configuration of a ConfigMap CR for caching Red Hat CoreOS (RHCOS) images. The distinction lies in their support for different protocols: HTTP or HTTPS.
>             - Protocol Used:
>                 - `01_ai_config.yaml`: Configures the use  of an HTTP web server. This is suitable for environments where security concerns are minimal or the network is isolated and secure, making HTTPS unnecessary.
>                 - `02_ai_config.yaml`: Configures the use of an HTTPS web server. HTTPS is the preferred protocol for environments requiring encrypted communication to protect data integrity and prevent unauthorized access.
>            - [99_00_lso_config.yaml](./hub-config/operators-config/99_00_lso_config.yaml):
>             ```yaml
>                nodeSelector:
>                 nodeSelectorTerms:
>                 - matchExpressions:
>                   - key: kubernetes.io/hostname
>                     operator: In
>                     values:
>                     - master0.b11oe21mno.dyn.onebts.example.com
>                     - master1.b11oe21mno.dyn.onebts.example.com
>                     - master2.b11oe21mno.dyn.onebts.example.com
>               storageClassDevices:
>               - devicePaths:
>                 - /dev/disk/by-path/pci-0000:00:11.5-ata-3
>              ```
>             The value `master{0,1,2}.b11oe21mno.dyn.onebts.example.com` must precisely match the FQDN of the HUB nodes in your environment, as these names are critical for proper node identification during deployment. A mismatch can lead to errors in assigning roles or managing the nodes. Verify node names using `oc get nodes` and ensure they align with the configuration. Similarly, the `devicePaths: /dev/disk/by-path/pci-0000:00:11.5-ata-3` must correspond to the actual disk path on each node, as this ensures the correct disk is used for storage or provisioning. Check these paths on the nodes using `ls -l /dev/disk/by-path/` and `lsblk`.
> To ensure accuracy, update your configuration files to reflect the correct node names and device paths. 
> 3. **Push to Your Git Server**:  
>    Once the necessary updates are complete, push the updated [hub-config](./hub-config/) directory to your Git server:  
>    ```bash
>    git add .
>    git commit -m "Updated hub-config for target environment version <version-number>"
>    git push <your-git-server-url>
>    ```
> 
> 4. **Verify the Environment Compatibility**:  
>    - Confirm that the configurations in the [hub-config](./hub-config/) repository reflect the intended environment's requirements. This ensures seamless installation and deployment.
>    - By ensuring the Git server mirrors the accurate [hub-config](./hub-config/) content tailored to the target version, you reduce the risk of misconfiguration, deployment > failures, and version mismatches during installation.
>    -  Create the [Hub ArgoCD Applications](./hub-config/hub-operators-argoapps.yaml):
>     ```bash
>     # oc create -f ./hub-config/hub-operators-argoapps.yaml
>     ```

> [!WARNING]
> Ensure that the Git-Server values are set according to your system for [hub-operators-argoapps.yaml](./hub-config/hub-operators-argoapps.yaml).
>
> Example used: 
> ```bash
> path: hub-config/operators-deployment
> repoURL: 'git@10.23.223.72:/home/git/acm.git'
> targetRevision: master
> ```

In the [hub-operators-argoapps.yaml](./hub-config/hub-operators-argoapps.yaml), the annotation `argocd.argoproj.io/sync-wave` determines the order in which resources are applied during a sync operation. Each resource annotated with this field is assigned to a "wave," and ArgoCD applies resources in ascending order of the wave values. This mechanism ensures proper sequencing of dependent resources.

Here's how the **sync-wave** values for the given resources influence their application order:

**Sync-Wave "0"**
- These resources are applied first since they have the lowest wave value:
  - **Provisioning**
  - **MultiClusterEngine**
  - **LocalVolume**
  - **ClusterRoleBinding**

These resources typically establish foundational configurations, roles, and infrastructure required by other components.

 **Sync-Wave "1"**
- These resources depend on the foundational setup:
  - **MultiClusterHub**
  - **OCSInitialization**
  - **StorageCluster**
  - **StorageSystem**

These are applied after the resources in wave "0," setting up critical subsystems like OpenShift Container Storage (OCS) and MultiClusterHub.

 **Sync-Wave "2"**
- These include configurations and services that require prior components to be active:
  - **ConfigMap (custom-registries)**
  - **ConfigMap (assisted-service-config)**
  - **AgentServiceConfig**

This wave prepares the necessary configurations and setups for services to function effectively.

 **Sync-Wave "20"**
- These are applied after all lower-wave components are in place:
  - **Secret (thanos-object-storage)**
  - **MultiClusterObservability**
  - **Namespace (ibu-odf-s3-storage)**

This high wave value ensures that these resources are configured only after all other dependencies are resolved.

_Why is `sync-wave` important?_

_Answer: In complex setups, resources often have dependencies, such as namespaces needing to exist before placing ConfigMaps, or a storage system requiring proper initial configuration before being utilized._ By leveraging sync-wave annotations:
- Resources are applied in the correct sequence.
- The risk of resource conflicts or misconfigurations is minimized.
- Multi-stage setups are coordinated smoothly.

_How to verify that operators in Openshift have been successfully deployed?_

_Answer: To verify that operators in OpenShift have been successfully deployed, follow the steps outlined in the OpenShift documentation [1], [2]. These steps ensure a systematic check of the Operator lifecycle management and deployment status:_ 

_- The Web Console manner:_ 

  _Access the OpenShift Web Console: Navigate to the OpenShift console and log in using appropriate credentials. This provides a graphical interface to check operator installations. Next step, check Installed Operators: `Go to Operators > Installed Operators in the console`. Verify the list of operators installed in the desired namespace. The status column will indicate whether the operator is running successfully (e.g., "Succeeded")._

_- The oc-cli manner:_
```bash
oc get csv -A | awk '!seen[$2]++'
```

 _The PHASE column will indicate whether the operator is running successfully (e.g., "Succeeded")_

_- Validate Operator Pods:_

_Use the OpenShift CLI (oc) to check the status of the pods related to the operator. Run the following command_
```bash
oc get pods -n <namespace>
```
_Replace <namespace> with the operator's namespace. All pods related to the operator should be in the "Running" or "Completed" state._
> [!WARNING]
> For the `OpenDataFundation Operator` follow the following [approach](https://github.com/midu16/l1-cp?tab=readme-ov-file#no-osd-pods-are-running-in-an-ocs-4x-cluster-even-when-the-osd-prepare-pods-are-in-completed-state-why).
_- Verify Operator Conditions:_
_Review the status of the operator's custom resource definitions (CRDs) to confirm they are functioning correctly:_
```bash
oc describe <crd-name> -n <namespace>
```
_Inspect the "Conditions" section for indications of readiness or errors._
_- Check Events and Logs:_
_If there are issues, inspect events for the namespace:_ 
```bash
oc get events -n <namespace>
```
_Additionally, check the logs of the operator's deployment or pod to identify errors:_
```bash
oc logs <pod-name> -n <namespace>
```
_Consult the Operator’s Documentation:_

_For specific operators, refer to the operator's documentation available in the OpenShift OperatorHub or the operator provider’s official documentation. This often contains troubleshooting steps and detailed requirements._

_Refer to the official OpenShift documentation for more details:_

_[1] : [OpenShift Operator Framework Overview](https://docs.openshift.com/container-platform/4.16/operators/understanding/olm-understanding-operatorhub.html)_

_[2] : [Troubleshooting Operator Issues](https://docs.openshift.com/container-platform/4.17/operators/admin/olm-troubleshooting-operator-issues.html)_

_By following these steps, you can systematically verify the deployment and operational status of operators in your OpenShift environment._

### Step 6. [Spoke deployment](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/edge_computing/ztp-deploying-far-edge-sites#ztp-deploying-far-edge-sites)

In this section we are going to outline the steps required to achieve a first RHACM Managed/Spoke(s) Deployment.

- Create the [Spoke ArgoCD Applications](./hub-config/spoke-argoapps.yaml):
```bash
# oc create -f ./hub-config/spoke-argoapps.yaml
```
> [!WARNING]
> Ensure that the Git-Server values are set according to your system for [spoke-argoapps.yaml](./hub-config/spoke-argoapps.yaml).
>

### Step 7. [Hub Cluster Audit and Infra Logs Aggregation](./audit_and_infra_logs_fw_to_hub.md)

In this section we are going to outline the method of procedure required to achieve the Spoke's Audit and Infra logs to the RHACM Hub Cluster.


### Step 8. [Hub Cluster Backup and Restore](./backup_and_restore.md)

In this section we are going to outline the method of procedure required to achieve the Backup and restore of the RHACM Hub Cluster.

### Step 9. [Hub Cluster Spoke's Observability](./observability_metrics_spoke_to_hub.md)

In this section we are going to outline the method of procedure required to achieve the Spoke's metrics aggregation on the RHACM Hub Cluster.

## Troubleshooting

Ensure to collect the following logs if the [AgentBasedInstaller fails during the installation](https://docs.openshift.com/container-platform/4.16/installing/installing_with_agent_based_installer/installing-with-agent-based-installer.html#installing-ocp-agent-gather-log_installing-with-agent-based-installer)

## Conclusions

### ArgoCD application management:

This can be easly achieved by using the `argocd` [client](https://argo-cd.readthedocs.io/en/stable/cli_installation/). 
  
- How to use the `argocd` client to interact with `gitops-operator` from `RHACM Hub Cluster` ?

*Answer:*

  - Obtain the `ArgoCD Password`:
```bash
# ARGOCD_PASS=$(oc get secret -n openshift-gitops openshift-gitops-cluster -o jsonpath='{.data.admin\.password}' | base64 --decode)
```
  - Obtain the `ArgoCD` Address:
```bash
# ARGOCD_ROUTE=$(oc get routes -n openshift-gitops -o jsonpath='{.items[?(@.metadata.name=="openshift-gitops-server")].spec.host}')
```
You can check the content fo the `ARGOCD_PASS` bash variable as follows:

```bash
# echo $ARGOCD_PASS
fAktrva8iwMBNFg9Wy5o4lnDHQs2zCZb
```

- Login to the `openshift-gitops` operator through `argocd` client:

```bash
# argocd login $ARGOCD_ROUTE
WARNING: server certificate had error: tls: failed to verify certificate: x509: certificate signed by unknown authority. Proceed insecurely (y/n)? y
WARN[0003] Failed to invoke grpc call. Use flag --grpc-web in grpc calls. To avoid this warning message, use flag --grpc-web.
Username: admin
Password:
'admin:login' logged in successfully
Context 'openshift-gitops-server-openshift-gitops.apps.hub.example.com' updated
```

- Synchronize the ArgoCD Application

```bash
argocd app sync clusters --force --prune
```

### No OSD pods are running in an OCS 4.x cluster, even when the [OSD Prepare pods are in Completed state](https://access.redhat.com/solutions/6910101), Why?

If you are redeploying the OCP Cluster and the application disks were previously used by another Ceph Cluster, ensure to perform the clean-up.

```bash
# sgdisk --zap-all /dev/sdb && sudo wipefs -a /dev/sdb
```

## Results and Problems

- It has not created the [gitops_service_cluster.yaml](./hub-config/operators-config/gitops_service_cluster.yaml).
- Once the ODF Hub Cluster its created, ensure the following steps are done:
  
  - master nodes gets labeled as below:
```bash
# oc label nodes master{0,1,2} cluster.ocs.openshift.io/openshift-storage=""
```
  - ensure that the application disks gets cleaned up:
```bash
# sgdisk --zap-all /dev/sdb && sudo wipefs -a /dev/sdb
```
