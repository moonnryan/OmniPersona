#!/usr/bin/env bash
set -euo pipefail

PAGES="${PAGES:-5}"
PER_PAGE="${PER_PAGE:-100}"
API_URL="https://api.github.com/repos/ggml-org/llama.cpp/releases"

found=0
for page in $(seq 1 "${PAGES}"); do
  curl -fsSL "${API_URL}?per_page=${PER_PAGE}&page=${page}" | /usr/bin/python3 -c '
import json
import sys

for release in json.load(sys.stdin):
    hits = []
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        lowered = name.lower()
        if any(key in lowered for key in ("mtmd", "multimodal", "mmproj")):
            hits.append((name, asset.get("browser_download_url", "")))
    if hits:
        print(release.get("tag_name", "unknown"))
        for name, url in hits:
            print(f"  {name}")
            print(f"  {url}")
'
done | tee /tmp/omnipersona-llama-mtmd-release-scan.txt

if [[ -s /tmp/omnipersona-llama-mtmd-release-scan.txt ]]; then
  found=1
fi

if [[ "${found}" == "0" ]]; then
  echo "No mtmd/multimodal/mmproj release asset found in the scanned pages."
fi
