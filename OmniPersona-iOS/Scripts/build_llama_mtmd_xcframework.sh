#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PINNED_LLAMA_VERSION_FILE="${ROOT_DIR}/ThirdParty/llama/VERSION"
if [[ -n "${RELEASE_TAG:-}" ]]; then
  TAG="${RELEASE_TAG}"
elif [[ -f "${PINNED_LLAMA_VERSION_FILE}" ]]; then
  TAG="$(tr -d '[:space:]' < "${PINNED_LLAMA_VERSION_FILE}")"
else
  TAG="b9789"
fi
SRC_ROOT="${ROOT_DIR}/ThirdParty/llama-src"
SRC_DIR="${SRC_ROOT}/llama.cpp-${TAG}"
OUT_DIR="${ROOT_DIR}/ThirdParty/llama-mtmd"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

mkdir -p "${SRC_ROOT}" "${OUT_DIR}"

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is required to build OmniLlamaMtmd.xcframework." >&2
  echo "Install CMake first, then rerun this script." >&2
  exit 127
fi

if [[ -n "${LLAMA_CPP_SOURCE_DIR:-}" ]]; then
  SRC_DIR="$(cd "${LLAMA_CPP_SOURCE_DIR}" && pwd)"
  echo "Using local llama.cpp source: ${SRC_DIR}"
elif [[ ! -d "${SRC_DIR}/.git" ]]; then
  git clone --depth 1 --branch "${TAG}" https://github.com/ggml-org/llama.cpp.git "${SRC_DIR}"
else
  git -C "${SRC_DIR}" fetch --depth 1 origin "${TAG}"
  git -C "${SRC_DIR}" checkout "${TAG}"
fi

if [[ ! -f "${SRC_DIR}/tools/mtmd/mtmd.h" ]]; then
  echo "tools/mtmd/mtmd.h is not present in ${TAG}; pick a newer tag." >&2
  exit 2
fi

if ! grep -R "mtmd" "${SRC_DIR}/CMakeLists.txt" "${SRC_DIR}/tools" -n >/dev/null 2>&1; then
  echo "Could not find mtmd CMake target references in ${TAG}." >&2
  exit 2
fi

build_one() {
  local sdk="$1"
  local archs="$2"
  local build_dir="${OUT_DIR}/build-${sdk}"
  local framework_dir="${OUT_DIR}/framework-${sdk}/OmniLlamaMtmd.framework"

  cmake -S "${SRC_DIR}" -B "${build_dir}" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${sdk}" \
    -DCMAKE_OSX_ARCHITECTURES="${archs}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_TOOLS=ON

  cmake --build "${build_dir}" --config Release --target llama mtmd

  rm -rf "${framework_dir}"
  mkdir -p "${framework_dir}/Headers" "${framework_dir}/Modules"

  local headers=(
    "${SRC_DIR}/include/llama.h"
    "${SRC_DIR}/ggml/include/ggml.h"
    "${SRC_DIR}/ggml/include/ggml-alloc.h"
    "${SRC_DIR}/ggml/include/ggml-backend.h"
    "${SRC_DIR}/ggml/include/ggml-cpu.h"
    "${SRC_DIR}/ggml/include/ggml-opt.h"
    "${SRC_DIR}/ggml/include/gguf.h"
    "${SRC_DIR}/tools/mtmd/mtmd.h"
    "${SRC_DIR}/tools/mtmd/mtmd-helper.h"
  )
  for header in "${headers[@]}"; do
    cp "${header}" "${framework_dir}/Headers/"
  done

  cat > "${framework_dir}/Headers/OmniLlamaMtmd.h" <<'EOF'
#pragma once
#include <OmniLlamaMtmd/llama.h>
#include <OmniLlamaMtmd/mtmd.h>
#include <OmniLlamaMtmd/mtmd-helper.h>
EOF

  find "${framework_dir}/Headers" -type f -name '*.h' -exec \
    perl -0pi -e 's/#include\s+"([^"]+\.h)"/#include <OmniLlamaMtmd\/$1>/g' {} \;

  cat > "${framework_dir}/Modules/module.modulemap" <<'EOF'
framework module OmniLlamaMtmd {
  umbrella header "OmniLlamaMtmd.h"
  export *
  module * { export * }
}
EOF

  /usr/bin/libtool -static -o "${framework_dir}/OmniLlamaMtmd" $(find "${build_dir}" -name '*.a' -type f | sort)
  cat > "${framework_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleName</key><string>OmniLlamaMtmd</string>
  <key>CFBundleIdentifier</key><string>com.local.OmniLlamaMtmd.${sdk}</string>
  <key>CFBundleVersion</key><string>${TAG}</string>
  <key>CFBundleShortVersionString</key><string>${TAG}</string>
</dict>
</plist>
EOF
}

build_one iphoneos arm64
build_one iphonesimulator "arm64;x86_64"

rm -rf "${OUT_DIR}/OmniLlamaMtmd.xcframework"
xcodebuild -create-xcframework \
  -framework "${OUT_DIR}/framework-iphoneos/OmniLlamaMtmd.framework" \
  -framework "${OUT_DIR}/framework-iphonesimulator/OmniLlamaMtmd.framework" \
  -output "${OUT_DIR}/OmniLlamaMtmd.xcframework"

echo "${TAG}" > "${OUT_DIR}/VERSION"
cat > "${OUT_DIR}/COMPATIBILITY.md" <<EOF
# OmniLlamaMtmd Compatibility

Built from ggml-org/llama.cpp ${TAG}.

Keep this framework version-paired with the app's llama.cpp headers and runtime.
When ThirdParty/llama/llama.xcframework is updated to a new release tag, rebuild
this framework with the same RELEASE_TAG.

Recommended update sequence:

1. Scripts/update_llama_xcframework.sh
2. Scripts/build_llama_mtmd_xcframework.sh
3. Rebuild the iOS app and run a text + multimodal smoke test.
EOF
echo "Installed ${OUT_DIR}/OmniLlamaMtmd.xcframework"
echo "Pinned version: ${TAG}"
