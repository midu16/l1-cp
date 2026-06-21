#!/usr/bin/env bash
# Merge idms-operator-supplement.yaml entries into idms-oc-mirror.yaml (idms-operator-0).
set -euo pipefail

MIRROR_PREFIX="${1:-infra.5g-deployment.lab:8443/hub-demo}"
IDMS_FILE="${2:-./workingdir/openshift/idms-oc-mirror.yaml}"
SUPPLEMENT_FILE="${3:-./workingdir/openshift/idms-operator-supplement.yaml}"

if [[ ! -f "$IDMS_FILE" ]]; then
  echo "Error: IDMS file not found: $IDMS_FILE" >&2
  exit 1
fi
if [[ ! -f "$SUPPLEMENT_FILE" ]]; then
  echo "Error: supplement file not found: $SUPPLEMENT_FILE" >&2
  exit 1
fi

python3 - "$MIRROR_PREFIX" "$IDMS_FILE" "$SUPPLEMENT_FILE" <<'PY'
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("Error: python3 PyYAML required (python3-yaml)\n")
    sys.exit(1)

prefix, idms_path, supplement_path = sys.argv[1:4]

with open(supplement_path, encoding="utf-8") as f:
    supplement_text = f.read().replace("${MIRROR_REGISTRY_PREFIX}", prefix)
    supplement = yaml.safe_load(supplement_text)

with open(idms_path, encoding="utf-8") as f:
    docs = list(yaml.safe_load_all(f))

new_entries = supplement.get("imageDigestMirrors") or []
added = 0

for doc in docs:
    if not doc:
        continue
    if doc.get("kind") != "ImageDigestMirrorSet":
        continue
    if doc.get("metadata", {}).get("name") != "idms-operator-0":
        continue
    spec = doc.setdefault("spec", {})
    mirrors = spec.setdefault("imageDigestMirrors", [])
    existing = {e.get("source") for e in mirrors if e.get("source")}
    for entry in new_entries:
        source = entry.get("source")
        if not source or source in existing:
            continue
        mirrors.append(
            {
                "mirrors": list(entry.get("mirrors") or []),
                "source": source,
            }
        )
        existing.add(source)
        added += 1

with open(idms_path, "w", encoding="utf-8") as f:
    yaml.dump_all(docs, f, default_flow_style=False, sort_keys=False)

print(f"Merged {added} supplemental IDMS entries into {idms_path}")
PY
