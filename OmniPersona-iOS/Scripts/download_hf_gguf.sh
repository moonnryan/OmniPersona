#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  cat >&2 <<'EOF'
Usage:
  HF_ENDPOINT=https://hf-mirror.com Scripts/download_hf_gguf.sh <repo-id>
  HF_ENDPOINT=https://hf-mirror.com Scripts/download_hf_gguf.sh <repo-id> <file.gguf>

Examples:
  Scripts/download_hf_gguf.sh mradermacher/Qwen3.5-4B-MiniFantasy-GGUF
  Scripts/download_hf_gguf.sh mradermacher/Qwen3.5-4B-MiniFantasy-GGUF model-Q4_K_M.gguf
EOF
  exit 2
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
REPO_ID="$1"
FILE_PATH="${2:-}"
OUT_DIR="${ROOT_DIR}/Models/${REPO_ID//\//__}"
mkdir -p "${OUT_DIR}"

if [[ -z "${FILE_PATH}" ]]; then
  API_URL="${HF_ENDPOINT}/api/models/${REPO_ID}/tree/main?recursive=true"
  curl -fsSL "${API_URL}" | /usr/bin/python3 - <<'PY'
import json
import sys
items = json.load(sys.stdin)
ggufs = []
for item in items:
    path = item.get("path", "")
    if path.lower().endswith(".gguf"):
        ggufs.append((path, item.get("size")))
def score(row):
    name = row[0].lower()
    if "q4_k_m" in name: return 0
    if "q4_0" in name: return 1
    if "q5" in name: return 2
    if "q3" in name: return 3
    return 9
for path, size in sorted(ggufs, key=score):
    suffix = f"  {size} bytes" if size else ""
    print(f"{path}{suffix}")
PY
  exit 0
fi

URL="${HF_ENDPOINT}/${REPO_ID}/resolve/main/${FILE_PATH}"
TARGET="${OUT_DIR}/$(basename "${FILE_PATH}")"
echo "Downloading ${URL}"
curl -fL "${URL}" -o "${TARGET}"
shasum -a 256 "${TARGET}" > "${TARGET}.sha256"
echo "Saved ${TARGET}"
