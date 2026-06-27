#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${ROOT_DIR}/ThirdParty/llama"
API_URL="https://api.github.com/repos/ggml-org/llama.cpp/releases"
RELEASE_TAG="${RELEASE_TAG:-latest}"
REQUIRE_MTMD="${REQUIRE_MTMD:-0}"

mkdir -p "${DEST_DIR}"

if [[ "${RELEASE_TAG}" == "latest" ]]; then
  RELEASE_JSON="$(curl -fsSL "${API_URL}/latest")"
else
  RELEASE_JSON="$(curl -fsSL "${API_URL}/tags/${RELEASE_TAG}")"
fi

ASSET_URL="$(
  RELEASE_JSON="${RELEASE_JSON}" /usr/bin/python3 - <<'PY'
import json
import os
release = json.loads(os.environ["RELEASE_JSON"])
assets = release.get("assets", [])
matches = []
for asset in assets:
    name = asset.get("name", "").lower()
    if "ios" in name and "xcframework" in name and name.endswith(".zip"):
        matches.append(asset.get("browser_download_url"))
if not matches:
    for asset in assets:
        name = asset.get("name", "").lower()
        if "xcframework" in name and name.endswith(".zip"):
            matches.append(asset.get("browser_download_url"))
if not matches:
    raise SystemExit("No iOS XCFramework zip asset found in release")
print(matches[0])
PY
)"

TAG="$(
  RELEASE_JSON="${RELEASE_JSON}" /usr/bin/python3 - <<'PY'
import json
import os
print(json.loads(os.environ["RELEASE_JSON"]).get("tag_name", "unknown"))
PY
)"

ZIP_PATH="${DEST_DIR}/llama-${TAG}-xcframework.zip"
TMP_DIR="${DEST_DIR}/.tmp-${TAG}"

echo "Downloading llama.cpp ${TAG} iOS XCFramework"
echo "Asset: ${ASSET_URL}"
curl -fL "${ASSET_URL}" -o "${ZIP_PATH}"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
ditto -x -k "${ZIP_PATH}" "${TMP_DIR}"

FOUND="$(find "${TMP_DIR}" -name 'llama.xcframework' -type d -maxdepth 5 | head -n 1)"
if [[ -z "${FOUND}" ]]; then
  echo "No llama.xcframework found after unzip" >&2
  exit 1
fi

rm -rf "${DEST_DIR}/llama.xcframework"
cp -R "${FOUND}" "${DEST_DIR}/llama.xcframework"
echo "${TAG}" > "${DEST_DIR}/VERSION"
shasum -a 256 "${ZIP_PATH}" > "${ZIP_PATH}.sha256"
rm -rf "${TMP_DIR}"

if find "${DEST_DIR}/llama.xcframework" -name 'mtmd.h' -type f | grep -q .; then
  echo "mtmd.h: present"
  echo "mtmd=present" > "${DEST_DIR}/CAPABILITIES"
else
  echo "mtmd.h: not present in upstream XCFramework"
  echo "mtmd=missing" > "${DEST_DIR}/CAPABILITIES"
  if [[ "${REQUIRE_MTMD}" == "1" ]]; then
    echo "This upstream release does not expose libmtmd. Use Scripts/build_llama_mtmd_xcframework.sh for a custom build." >&2
    exit 2
  fi
fi

echo "Installed ${DEST_DIR}/llama.xcframework"
echo "Pinned version: ${TAG}"
