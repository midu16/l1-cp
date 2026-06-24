#!/usr/bin/env bash
# Merge oc-mirror IDMS output into workingdir/openshift/idms-oc-mirror.yaml, preserving
# supplemental operator mirrors embedded in the template (idms-operator-0 tail section).
set -euo pipefail

OC_MIRROR_SRC="${1:?oc-mirror idms-oc-mirror.yaml path required}"
IDMS_DST="${2:-./workingdir/openshift/idms-oc-mirror.yaml}"

if [[ ! -f "$OC_MIRROR_SRC" ]]; then
  echo "Error: oc-mirror IDMS not found: $OC_MIRROR_SRC" >&2
  exit 1
fi

python3 - "$OC_MIRROR_SRC" "$IDMS_DST" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("Error: python3 PyYAML required (python3-yaml)\n")
    sys.exit(1)

oc_mirror_src, idms_dst = sys.argv[1:3]
dst_path = Path(idms_dst)
placeholder = "${MIRROR_REGISTRY_PREFIX}"

HEADER = (
    "# Airgap mirror prefix for ImageDigestMirrorSet mirror paths.\n"
    "# Render with: scripts/render-idms-oc-mirror.sh <registry>/hub-demo workingdir/openshift/idms-oc-mirror.yaml\n"
    f"# MIRROR_REGISTRY_PREFIX={placeholder}\n\n"
)

SUPPLEMENT_MARKER = (
    "# Supplemental operator mirrors (oc-mirror often omits IDMS mappings for relatedImages)."
)

# Sources maintained in workingdir/openshift/idms-oc-mirror.yaml after SUPPLEMENT_MARKER.
SUPPLEMENT_SOURCES = {
    "registry.redhat.io/rhceph/rhceph-9-rhel9",
    "registry.redhat.io/openshift-gitops-1/argocd-rhel9",
    "registry.redhat.io/openshift-gitops-1/dex-rhel9",
    "registry.redhat.io/openshift-gitops-1/console-plugin-rhel9",
    "registry.redhat.io/openshift-gitops-1/gitops-rhel9",
    "registry.redhat.io/odf4/odf-blackbox-exporter-rhel9",
    "registry.redhat.io/rhel9/postgresql-16",
    "registry.redhat.io/odf4/mcg-core-rhel9",
    "registry.redhat.io/odf4/odf-cloudnative-pg-rhel9-operator",
    "registry.redhat.io/odf4/odf-external-snapshotter-rhel9-operator",
    "registry.redhat.io/odf4/odf-external-snapshotter-sidecar-rhel9",
    "registry.redhat.io/openshift4/ztp-site-generate-rhel8",
    "registry.redhat.io/rhel8/support-tools",
    "registry.redhat.io/rhel9/support-tools",
    "registry.redhat.io/multicluster-engine/cluster-permission-rhel9",
    "registry.redhat.io/oadp/oadp-cli-binaries-rhel9",
    "registry.redhat.io/oadp/oadp-vmdp-binaries-rhel9",
    "registry.redhat.io/openshift-gitops-1/gitops-rhel9-operator",
}


def normalize_mirror_path(path: str) -> str:
    if not path:
        return path
    if path.startswith(placeholder):
        return path
    marker = "/hub-demo/"
    if marker in path:
        rel = path.split(marker, 1)[1]
        return f"{placeholder}/{rel}"
    return path


def normalize_doc(doc):
    if not doc:
        return
    for entry in doc.get("spec", {}).get("imageDigestMirrors") or []:
        if not isinstance(entry, dict):
            continue
        entry["mirrors"] = [normalize_mirror_path(m) for m in entry.get("mirrors") or []]


def load_docs(path: Path):
    if not path.is_file():
        return []
    text = path.read_text(encoding="utf-8")
    if text.startswith("# Airgap mirror prefix"):
        text = text.split("\n\n", 1)[1]
    return list(yaml.safe_load_all(text))


def supplement_entries_from_doc(doc):
    if not doc:
        return []
    return [
        entry
        for entry in doc.get("spec", {}).get("imageDigestMirrors") or []
        if isinstance(entry, dict) and entry.get("source") in SUPPLEMENT_SOURCES
    ]


def merge_supplements(target_doc, supplement_entries):
    if not supplement_entries:
        return 0
    spec = target_doc.setdefault("spec", {})
    mirrors = spec.setdefault("imageDigestMirrors", [])
    existing = {e.get("source") for e in mirrors if isinstance(e, dict) and e.get("source")}
    added = 0
    if not any(isinstance(e, str) and e.startswith(SUPPLEMENT_MARKER) for e in mirrors):
        mirrors.append(SUPPLEMENT_MARKER)
    for entry in supplement_entries:
        source = entry.get("source")
        if not source or source in existing:
            continue
        mirrors.append(
            {
                "mirrors": [normalize_mirror_path(m) for m in entry.get("mirrors") or []],
                "source": source,
            }
        )
        existing.add(source)
        added += 1
    return added


existing_docs = load_docs(dst_path)
existing_operator = next(
    (
        doc
        for doc in existing_docs
        if doc.get("kind") == "ImageDigestMirrorSet"
        and doc.get("metadata", {}).get("name") == "idms-operator-0"
    ),
    None,
)
supplement_entries = supplement_entries_from_doc(existing_operator)

with open(oc_mirror_src, encoding="utf-8") as f:
    docs = list(yaml.safe_load_all(f))

for doc in docs:
    normalize_doc(doc)

operator_doc = next(
    (
        doc
        for doc in docs
        if doc.get("kind") == "ImageDigestMirrorSet"
        and doc.get("metadata", {}).get("name") == "idms-operator-0"
    ),
    None,
)
added = 0
if operator_doc:
    added = merge_supplements(operator_doc, supplement_entries)

# Drop string marker before writing; comment is re-inserted in idms-oc-mirror.yaml template.
if operator_doc:
    operator_doc["spec"]["imageDigestMirrors"] = [
        e for e in operator_doc["spec"]["imageDigestMirrors"]
        if not (isinstance(e, str) and e.startswith("# Supplemental operator mirrors"))
    ]

dst_path.parent.mkdir(parents=True, exist_ok=True)
with open(dst_path, "w", encoding="utf-8") as f:
    f.write(HEADER)
    yaml.dump_all(docs, f, default_flow_style=False, sort_keys=False)

text = dst_path.read_text(encoding="utf-8")
marker_line = f"  {SUPPLEMENT_MARKER}\n"
if marker_line not in text:
    for source in sorted(SUPPLEMENT_SOURCES):
        needle = f"    source: {source}\n"
        if needle in text:
            text = text.replace(needle, f"{marker_line}{needle}", 1)
            break
    dst_path.write_text(text, encoding="utf-8")

print(f"Synced IDMS from {oc_mirror_src} -> {idms_dst}")
if supplement_entries:
    print(f"  Preserved {len(supplement_entries)} supplemental mirror entries ({added} newly merged)")
PY
