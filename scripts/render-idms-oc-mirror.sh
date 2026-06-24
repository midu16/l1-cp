#!/usr/bin/env bash
# Replace ${MIRROR_REGISTRY_PREFIX} in idms-oc-mirror.yaml with the airgap registry path.
set -euo pipefail

MIRROR_PREFIX="${1:?mirror prefix required, e.g. infra.5g-deployment.lab:8443/hub-demo}"
IDMS_FILE="${2:-./workingdir/openshift/idms-oc-mirror.yaml}"

if [[ ! -f "$IDMS_FILE" ]]; then
  echo "Error: IDMS file not found: $IDMS_FILE" >&2
  exit 1
fi

python3 - "$MIRROR_PREFIX" "$IDMS_FILE" <<'PY'
import sys
from pathlib import Path

prefix, idms_path = sys.argv[1:3]
path = Path(idms_path)
text = path.read_text(encoding="utf-8")
placeholder = "${MIRROR_REGISTRY_PREFIX}"
if placeholder not in text:
    print(f"No {placeholder} placeholders in {idms_path}; nothing to render")
    sys.exit(0)
text = text.replace(placeholder, prefix)
if text.startswith("# Airgap mirror prefix"):
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("# MIRROR_REGISTRY_PREFIX="):
            lines[i] = f"# MIRROR_REGISTRY_PREFIX={prefix}"
            break
    text = "\n".join(lines) + ("\n" if text.endswith("\n") else "")
path.write_text(text, encoding="utf-8")
print(f"Rendered {idms_path} with MIRROR_REGISTRY_PREFIX={prefix}")
PY
