## **Jira Task: Implement Registry Content Lifecycle Management for EUS2EUS Upgrades**

### **Summary**

Optimize storage management by defining and implementing a registry cleanup strategy for deprecated releases, specifically targeting the transition period during Extended User Support (EUS) to EUS upgrades.

### **Context**

As we move through the **EUS2EUS (Extended User Support)** upgrade path, legacy container images and registry artifacts from skipped or intermediate versions accumulate, leading to significant storage overhead. To maintain a lean infrastructure, we need a systematic way to identify and purge these "bridge" or deprecated releases without breaking the upgrade path or production stability.

### **Scope of Work**

1. **Audit Current Registry State:** Identify the top 10% of images consuming the most storage and map them to specific release versions.
2. **Define Retention Policy:** * Establish which "source" EUS artifacts must remain immutable.
* Identify "transient" artifacts (intermediate builds/patches) that are safe for deletion post-upgrade.


3. **Automation Scripting/Tooling:** Develop or configure a cleanup job (e.g., using `regctl`, `skopeo`, or native cloud registry lifecycle policies) to automate the deprecation.
4. **Validation:** Ensure that the cleanup does not impact the rollback capability for the current EUS target.

### **Acceptance Criteria**

* [ ] **Inventory Report:** A list of deprecated releases and their associated storage footprint is generated.
* [ ] **Policy Documentation:** A clear "keep/discard" matrix is documented in Confluence/Wiki.
* [ ] **Automated Cleanup:** A scheduled task or script is functional in the staging environment.
* [ ] **Storage Recovery:** Successful reduction of registry storage by at least **[X]%** (to be defined after audit).
* [ ] **Zero Downtime:** Cleanup must not affect active deployments or ongoing EUS2EUS upgrade procedures.

### **Technical Notes**

* **Safety First:** Use "dry-run" modes for all deletion scripts initially.
* **Dependencies:** Ensure no downstream CI/CD pipelines are hard-coded to pull from deprecated tags that are slated for removal.

---

## **Target Air-Gapped Registry**

| Item | Value |
|------|--------|
| **Registry URL** | `https://infra.5g-deployment.lab:8443` |
| **Auth** | `pi:raspberry` (user:password) |
| **TLS** | Use `--insecure` / `-k` for self-signed or internal CA |

**Quick connectivity check:**

```bash
curl -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/_catalog" --insecure | jq .
```

**Validation:** HTTP 200 and JSON with a `repositories` array (e.g. `{"repositories":["repo1","repo2",...]}`).

---

## **Step-by-Step Procedures**

### **Phase 1: Audit Current Registry State**

Goal: Identify repositories, map tags to release versions, and (where possible) estimate storage to find the top consumers.

#### **Step 1.1 — Verify Registry API and list all repositories**

1. **Check API version (v2):**
   ```bash
   curl -s -o /dev/null -w "%{http_code}" -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/" --insecure
   ```
   **Validation:** Response code `200`. Optional: `curl -sI -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/" --insecure` and confirm header `Docker-Distribution-Api-Version: registry/2.0`.

2. **List full catalog (all repositories):**
   ```bash
   curl -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/_catalog" --insecure | jq .
   ```
   For large registries, paginate with `?n=1000` (and `&last=<last_repo>` if supported):
   ```bash
   curl -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/_catalog?n=1000" --insecure | jq .
   ```
   **Validation:** JSON object with key `repositories`; count repos: `jq '.repositories | length'`.

3. **Save baseline catalog for later comparison:**
   ```bash
   curl -s -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/_catalog" --insecure | jq . > registry_catalog_baseline.json
   ```

#### **Step 1.2 — List tags per repository (map to release versions)**

For each repository from Step 1.1, list tags to map image tags to OCP/release versions (e.g. `4.18`, `4.19`, `release-images`, operator indices).

1. **Set registry base and auth (reuse in all steps):**
   ```bash
   export REGISTRY_URL="https://infra.5g-deployment.lab:8443"
   export REGISTRY_AUTH="pi:raspberry"
   export REGISTRY_OPTS="-u ${REGISTRY_AUTH} --insecure"
   ```

2. **List tags for a single repository** (replace `<repository>` with a repo from `_catalog`, e.g. `hub-demo/openshift-marketplace/redhat-operators-disconnected`):
   ```bash
   curl -X GET -u pi:raspberry "${REGISTRY_URL}/v2/<repository>/tags/list" --insecure | jq .
   ```
   Example:
   ```bash
   curl -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/hub-demo/openshift-marketplace/redhat-operators-disconnected/tags/list" --insecure | jq .
   ```
   **Validation:** JSON with `name` and `tags` array; extract version-like tags (e.g. `v4.18`, `v4.19`, `4.18.23-x86_64`).

3. **Generate full inventory (all repos and their tags)** for audit and retention mapping:
   ```bash
   REGISTRY_URL="https://infra.5g-deployment.lab:8443"
   for repo in $(curl -s -X GET -u pi:raspberry "${REGISTRY_URL}/v2/_catalog" --insecure | jq -r '.repositories[]'); do
     echo "=== $repo ==="
     curl -s -X GET -u pi:raspberry "${REGISTRY_URL}/v2/${repo}/tags/list" --insecure | jq -r '.tags[]?' 2>/dev/null | sort -u
   done | tee registry_tags_inventory.txt
   ```
   **Validation:** `registry_tags_inventory.txt` contains every repo and its tags; use it to identify release/version patterns (EUS vs transient).

#### **Step 1.3 — Optional: get manifest (digest/layers) for size estimation**

Registry API does not return size in `_catalog` or `tags/list`. To estimate per-image size you can:

1. **Get manifest for a tag** (required header for schema v2):
   ```bash
   repo="hub-demo/openshift-marketplace/redhat-operators-disconnected"
   tag="v4.19"
   curl -s -X GET -u pi:raspberry \
     -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
     "${REGISTRY_URL}/v2/${repo}/manifests/${tag}" --insecure | jq .
   ```
   **Validation:** JSON with `config` and `layers`; each layer has `size` (bytes). Sum of `layers[].size` + config size ≈ image size.

2. **Use tooling for storage audit (recommended for “top 10%”):**
   - **regctl:** list repos/tags and digests; combine with blob sizes on registry server if you have filesystem access.
   - **On registry server:** run `du -sh /var/lib/registry/docker/registry/v2/...` (path depends on deployment) to find largest blobs/repos.
   - **Inventory report:** from Step 1.2 + manifest sizes (or server-side du), build a table: repository, tags, version (e.g. 4.18 / 4.19), estimated size; sort by size and take top 10%.

---

### **Phase 2: Define Retention Policy (Keep/Discard Matrix)**

#### **Step 2.1 — Document current EUS target and “source” artifacts**

1. Define and document:
   - **Current EUS target** (e.g. 4.19).
   - **Repositories that must remain immutable** (e.g. `hub-demo/openshift/release-images`, current operator index, any rollback-critical paths).
2. **Validation:** Written policy lists repo names (or patterns) and “KEEP” with reason (e.g. “current EUS release”, “rollback”).

#### **Step 2.2 — Identify transient/deprecated artifacts**

1. From `registry_tags_inventory.txt` and your release matrix, list:
   - Tags/repos that are **intermediate or deprecated** (e.g. old 4.18 after upgrade to 4.19, or bridge builds).
2. **Validation:** A “DISCARD” list (repos and/or tags) with version rationale (e.g. “4.18, superseded by 4.19”).

#### **Step 2.3 — Keep/Discard matrix (policy documentation)**

| Repository (or pattern) | Tags / versions | Action | Reason |
|--------------------------|------------------|--------|--------|
| e.g. `hub-demo/openshift/release-images` | Current EUS (e.g. 4.19.x) | **KEEP** | Active EUS target |
| e.g. `hub-demo/openshift-marketplace/redhat-operators-disconnected` | `v4.19` | **KEEP** | Current operator index |
| Same or other | `v4.18`, old patch tags | **DISCARD** (after validation) | Deprecated / transient |

**Validation:** Matrix is documented (Confluence/Wiki or this doc); all items from 2.1 and 2.2 are covered.

---

### **Phase 3: Automation Scripting / Cleanup (Dry-Run First)**

Use Registry API + regctl (or skopeo) for deletes. Always start with dry-run.

#### **Step 3.1 — Configure regctl for target registry (optional but recommended)**

```bash
regctl registry set infra.5g-deployment.lab:8443 \
  --user pi --pass raspberry --tls disabled
```

**Validation:** `regctl tag ls infra.5g-deployment.lab:8443/hub-demo/openshift-marketplace/redhat-operators-disconnected` lists tags (or equivalent repo).

#### **Step 3.2 — Dry-run: list what would be deleted**

1. Generate a list of tags (or digest refs) from the DISCARD matrix (Phase 2).
2. **Do not delete yet.** Only list:
   ```bash
   # Example: list tags that match “deprecated” (customize pattern to your DISCARD list)
   REGISTRY="infra.5g-deployment.lab:8443"
   repo="hub-demo/openshift-marketplace/redhat-operators-disconnected"
   regctl tag ls "${REGISTRY}/${repo}" --include "v4.18*"
   ```
3. Write the dry-run output to a file and review:
   ```bash
   regctl tag ls "${REGISTRY}/${repo}" > candidate_tags_dryrun.txt
   ```
   **Validation:** No delete commands run; file contains only tag names; confirm they match DISCARD policy.

#### **Step 3.3 — Deletion (only after dry-run and approval)**

- **By tag (recommended where supported):** Use `regctl tag rm <image>:<tag>` in a loop over approved tags.
- **By digest:** `regctl image delete <image>@<digest>` (removes manifest and all tags pointing to it).
- **Safety:** Run first on a single deprecated tag; then re-run Phase 1.2 and 4.1 to validate.

Example (run only after policy approval and dry-run):

```bash
# Example: remove a single deprecated tag (customize repo and tag)
regctl tag rm infra.5g-deployment.lab:8443/hub-demo/some/repo:v4.18-old
```

**Validation:** After delete, `curl .../v2/<repo>/tags/list` no longer shows the removed tag; current EUS tags still present.

---

### **Phase 4: Validation (Post-Cleanup and Rollback Safety)**

#### **Step 4.1 — Re-list catalog and tags**

1. **Catalog after cleanup:**
   ```bash
   curl -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/_catalog" --insecure | jq . > registry_catalog_after_cleanup.json
   ```
2. **Compare with baseline:** Repositories that were only used for deprecated tags might still appear (registry often keeps repo entry until empty); focus on tags.
3. **Re-run tag inventory (Step 1.2)** and save:
   ```bash
   # Same loop as Step 1.2, output to registry_tags_after_cleanup.txt
   ```
   **Validation:** Deprecated tags from DISCARD list are gone; KEEP list tags still present.

#### **Step 4.2 — Verify current EUS and rollback capability**

1. Confirm tags required for **current EUS target** (e.g. 4.19) and **one rollback version** (if applicable) still exist:
   ```bash
   repo="hub-demo/openshift/release-images"   # adjust to your release repo
   curl -s -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/${repo}/tags/list" --insecure | jq '.tags[]' | grep -E "4\.19\.|4\.18\."
   ```
2. **Validation:** Required release tags (e.g. 4.19.x, 4.18.x for rollback) are still in `tags/list`; no active deployment points to removed tags.

#### **Step 4.3 — Zero-downtime check**

1. Ensure no running pipelines or clusters reference removed tags (grep CI/CD and install-configs for deprecated image refs).
2. **Validation:** No workload or job pulls an image that was deleted; cleanup did not affect active deployments or ongoing EUS2EUS procedures.

---

## **Procedure Summary**

| Phase | Steps | Main validation |
|-------|--------|------------------|
| **1. Audit** | 1.1 API + catalog, 1.2 tags per repo, 1.3 manifest/size | Baseline catalog + full tag inventory; optional size report |
| **2. Retention** | 2.1 KEEP list, 2.2 DISCARD list, 2.3 Matrix | Policy doc and keep/discard matrix complete |
| **3. Automation** | 3.1 regctl config, 3.2 dry-run list, 3.3 delete (after approval) | Dry-run only first; deletes match policy |
| **4. Validation** | 4.1 catalog/tags after cleanup, 4.2 EUS/rollback tags, 4.3 no broken refs | Discarded tags gone; keep list intact; zero downtime |

All methods use the same registry base: **`https://infra.5g-deployment.lab:8443`** with **`-u pi:raspberry`** and **`--insecure`**. Adjust repository names and tag patterns to match your actual `_catalog` and retention policy.

---

## **Namespace-Level Operations**

When the registry organizes content by **namespace** (first path component), e.g. `hub-demo-418`, `hub-demo-419`, `hub-demo-420`, you can perform the same lifecycle operations at namespace level and **safely remove one entire namespace** (e.g. deprecated `hub-demo-418`) with minimal impact on the rest of the registry.

In the Registry v2 API, a "namespace" is the **repository name prefix** (e.g. all repositories whose name starts with `hub-demo-418/`). There is no separate namespace API; you filter the catalog by prefix.

### **Scenario: Three namespaces (hub-demo-418, hub-demo-419, hub-demo-420)**

| Namespace      | Purpose (example)     | Action   |
|----------------|------------------------|----------|
| `hub-demo-418` | Old EUS (4.18)        | **Remove** after upgrade |
| `hub-demo-419` | Current EUS (4.19)    | **Keep** (active)        |
| `hub-demo-420` | Next EUS (4.20)       | **Keep** (active)        |

---

### **Phase N1: Audit at namespace level**

#### **Step N1.1 — List repositories per namespace**

1. **Get full catalog and group by namespace (first path segment):**
   ```bash
   REGISTRY_URL="https://infra.5g-deployment.lab:8443"
   curl -s -X GET -u pi:raspberry "${REGISTRY_URL}/v2/_catalog" --insecure | jq -r '.repositories[]' | sort -u > all_repos.txt
   ```
2. **List unique namespace prefixes** (first path component before `/`):
   ```bash
   cut -d'/' -f1 all_repos.txt | sort -u
   ```
   **Validation:** You see `hub-demo-418`, `hub-demo-419`, `hub-demo-420` (or your actual prefixes).

3. **List all repositories under a single namespace** (e.g. the one to be removed):
   ```bash
   NAMESPACE_TO_AUDIT="hub-demo-418"
   grep "^${NAMESPACE_TO_AUDIT}/" all_repos.txt
   ```
   Or with jq only:
   ```bash
   curl -s -X GET -u pi:raspberry "${REGISTRY_URL}/v2/_catalog" --insecure | \
     jq -r --arg ns "${NAMESPACE_TO_AUDIT}" '.repositories[] | select(startswith($ns + "/"))'
   ```
   **Validation:** Output is the full list of repo names under that namespace; no repos from other namespaces.

4. **Save per-namespace inventory for baseline:**
   ```bash
   for ns in hub-demo-418 hub-demo-419 hub-demo-420; do
     echo "=== Namespace: $ns ==="
     curl -s -X GET -u pi:raspberry "${REGISTRY_URL}/v2/_catalog" --insecure | \
       jq -r --arg n "$ns" '.repositories[] | select(startswith($n + "/"))'
   done | tee registry_namespace_baseline.txt
   ```

#### **Step N1.2 — List tags for all repositories in one namespace**

1. **Generate tag inventory for the namespace you plan to remove** (dry-run for deletion list):
   ```bash
   REGISTRY_URL="https://infra.5g-deployment.lab:8443"
   NAMESPACE_TO_REMOVE="hub-demo-418"

   for repo in $(curl -s -X GET -u pi:raspberry "${REGISTRY_URL}/v2/_catalog" --insecure | \
                 jq -r --arg ns "${NAMESPACE_TO_REMOVE}" '.repositories[] | select(startswith($ns + "/"))'); do
     echo "=== $repo ==="
     curl -s -X GET -u pi:raspberry "${REGISTRY_URL}/v2/${repo}/tags/list" --insecure | jq -r '.tags[]?' 2>/dev/null | sort -u
   done | tee namespace_${NAMESPACE_TO_REMOVE}_tags_inventory.txt
   ```
   **Validation:** File contains only repos under `hub-demo-418/` and their tags; no data from `hub-demo-419` or `hub-demo-420`.

---

### **Phase N2: Retention policy at namespace level**

#### **Step N2.1 — Define which namespaces to keep vs remove**

1. **KEEP namespaces:** Active EUS and any still needed (e.g. `hub-demo-419`, `hub-demo-420`). Document why (e.g. "current EUS", "next EUS").
2. **DISCARD namespace:** Deprecated EUS only (e.g. `hub-demo-418`). Confirm no active deployments or CI/CD reference it.
3. **Validation:** Grep codebase and configs for image refs containing the namespace to remove:
   ```bash
   grep -r "hub-demo-418" /path/to/install-configs /path/to/workflows /path/to/manifests || true
   ```
   **Validation:** No references (or only in deprecated docs); safe to remove `hub-demo-418`.

#### **Step N2.2 — Keep/Discard matrix (namespace level)**

| Namespace      | Repositories (prefix)     | Action   | Reason                    |
|----------------|---------------------------|----------|---------------------------|
| `hub-demo-418` | `hub-demo-418/*`          | **DISCARD** | Deprecated EUS 4.18      |
| `hub-demo-419` | `hub-demo-419/*`          | **KEEP**   | Current EUS 4.19         |
| `hub-demo-420` | `hub-demo-420/*`          | **KEEP**   | Next EUS 4.20           |

**Validation:** Only one namespace is marked DISCARD; all others KEEP; no overlap.

---

### **Phase N3: Safely remove one namespace**

Goal: Delete **all content under one namespace** (e.g. `hub-demo-418`) without touching `hub-demo-419` or `hub-demo-420`, preserving service integrity.

#### **Step N3.1 — Dry-run: list what would be deleted**

1. **List every repository in the namespace to remove:**
   ```bash
   REGISTRY_URL="https://infra.5g-deployment.lab:8443"
   NAMESPACE_TO_REMOVE="hub-demo-418"

   curl -s -X GET -u pi:raspberry "${REGISTRY_URL}/v2/_catalog" --insecure | \
     jq -r --arg ns "${NAMESPACE_TO_REMOVE}" '.repositories[] | select(startswith($ns + "/"))' > repos_to_delete_dryrun.txt
   wc -l repos_to_delete_dryrun.txt
   cat repos_to_delete_dryrun.txt
   ```
   **Validation:** Only repos starting with `hub-demo-418/`; no `hub-demo-419` or `hub-demo-420` in the list.

2. **List every tag that would be removed** (repo:tag per line for audit):
   ```bash
   while IFS= read -r repo; do
     curl -s -X GET -u pi:raspberry "${REGISTRY_URL}/v2/${repo}/tags/list" --insecure | \
       jq -r --arg r "$repo" '.tags[]? | "\($r):\(.)"'
   done < repos_to_delete_dryrun.txt | tee tags_to_delete_dryrun.txt
   ```
   **Validation:** Review `tags_to_delete_dryrun.txt`; all lines must be under the DISCARD namespace only.

#### **Step N3.2 — Delete all tags in the namespace (then optionally blobs)**

Registry v2 typically does not support "delete repository"; you delete by **tag** or **manifest (digest)**. Removing all tags in a repository effectively makes that repo empty (blobs may remain until garbage-collected).

1. **Option A — Delete by tag with regctl (recommended, one namespace only):**
   ```bash
   REGISTRY="infra.5g-deployment.lab:8443"
   NAMESPACE_TO_REMOVE="hub-demo-418"

   # Dry-run: only print, do not delete
   while IFS= read -r repo; do
     for tag in $(curl -s -X GET -u pi:raspberry "https://${REGISTRY}/v2/${repo}/tags/list" --insecure | jq -r '.tags[]?' 2>/dev/null); do
       echo "[DRY-RUN] would delete: ${REGISTRY}/${repo}:${tag}"
     done
   done < repos_to_delete_dryrun.txt

   # Actual deletion (run only after approval; remove 'echo' and use real regctl)
   # regctl registry set ${REGISTRY} --user pi --pass raspberry --tls disabled
   # while IFS= read -r repo; do
   #   for tag in $(curl -s -X GET -u pi:raspberry "https://${REGISTRY}/v2/${repo}/tags/list" --insecure | jq -r '.tags[]?' 2>/dev/null); do
   #     regctl tag rm "${REGISTRY}/${repo}:${tag}"
   #   done
   # done < repos_to_delete_dryrun.txt
   ```
   **Validation:** Dry-run output contains only `hub-demo-418/...` images; after real run, no tags left under that namespace.

2. **Option B — Script that deletes only within the target namespace (safety check):**
   ```bash
   NAMESPACE_TO_REMOVE="hub-demo-418"
   REGISTRY="infra.5g-deployment.lab:8443"

   while IFS= read -r repo; do
     if [[ ! "$repo" == "${NAMESPACE_TO_REMOVE}"/* ]]; then
       echo "SKIP (wrong namespace): $repo"
       continue
     fi
     for tag in $(curl -s -X GET -u pi:raspberry "https://${REGISTRY}/v2/${repo}/tags/list" --insecure | jq -r '.tags[]?' 2>/dev/null); do
       echo "Deleting ${REGISTRY}/${repo}:${tag}"
       regctl tag rm "${REGISTRY}/${repo}:${tag}"
     done
   done < repos_to_delete_dryrun.txt
   ```
   **Validation:** Script never touches repos that do not start with `hub-demo-418/`; other namespaces unchanged.

#### **Step N3.3 — Run registry garbage collection (if available)**

After deleting tags/manifests, blobs may remain until the registry runs garbage collection. If you have access to the registry process:

```bash
# On the registry host (example for Distribution registry)
# registry garbage-collect /path/to/config.yml
```

**Validation:** Storage on disk decreases after GC; only blobs no longer referenced by any manifest are removed.

---

### **Phase N4: Validation after namespace removal**

#### **Step N4.1 — Confirm removed namespace has no (or minimal) content**

1. **List repositories under the removed namespace:**
   ```bash
   curl -s -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/_catalog" --insecure | \
     jq -r '.repositories[] | select(startswith("hub-demo-418/"))'
   ```
   **Validation:** Empty output (no repos) or only repo names with zero tags (repos may remain until GC or registry implementation).

2. **List tags for any remaining repo under that namespace:**
   ```bash
   for repo in $(curl -s -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/_catalog" --insecure | \
                 jq -r '.repositories[] | select(startswith("hub-demo-418/"))'); do
     echo "=== $repo ==="
     curl -s -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/${repo}/tags/list" --insecure | jq '.tags'
   done
   ```
   **Validation:** All `tags` arrays empty or missing; no pullable images under `hub-demo-418`.

#### **Step N4.2 — Confirm other namespaces are intact**

1. **List repositories under KEEP namespaces:**
   ```bash
   for ns in hub-demo-419 hub-demo-420; do
     echo "=== Namespace: $ns ==="
     curl -s -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/_catalog" --insecure | \
       jq -r --arg n "$ns" '.repositories[] | select(startswith($n + "/"))'
   done
   ```
   **Validation:** Same repo list as before removal (no repos deleted from `hub-demo-419` or `hub-demo-420`).

2. **Spot-check tags for a critical repo in a KEEP namespace:**
   ```bash
   curl -s -X GET -u pi:raspberry "https://infra.5g-deployment.lab:8443/v2/hub-demo-419/openshift/release-images/tags/list" --insecure | jq .
   ```
   **Validation:** Tags list unchanged; service and upgrades can still pull images from `hub-demo-419` and `hub-demo-420`.

#### **Step N4.3 — Service and integrity checks**

1. **No references to removed namespace:** Re-run grep for `hub-demo-418` in configs; fix any remaining references to point to active namespace.
2. **Active deployments:** Confirm pods/workloads pull only from `hub-demo-419` or `hub-demo-420`; no ImagePullBackOff or missing image for `hub-demo-418`.
3. **Validation:** Zero impact (or minimal impact limited to deprecated content) on service and other content; rollback capability for current EUS preserved if it uses a kept namespace.

---

## **Namespace-Level Procedure Summary**

| Phase | Steps | Main validation |
|-------|--------|------------------|
| **N1. Audit** | N1.1 list repos per namespace, N1.2 tags per namespace | Baseline per-namespace inventory; only target namespace in discard list |
| **N2. Retention** | N2.1 keep/discard namespaces, N2.2 matrix | One namespace DISCARD; no refs in active configs |
| **N3. Remove** | N3.1 dry-run list, N3.2 delete by tag (with prefix check), N3.3 GC | Only `hub-demo-418` content removed; 419/420 untouched |
| **N4. Validation** | N4.1 removed namespace empty, N4.2 other namespaces intact, N4.3 no broken refs | Service integrity and zero/minimal impact confirmed |
