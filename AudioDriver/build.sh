#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${ROOT}/build"
LIBASPL="${ROOT}/../../libASPL"

if [[ ! -d "${LIBASPL}" ]]; then
  echo "libASPL not found at ${LIBASPL} — clone https://github.com/gavv/libASPL next to Voxa"
  exit 1
fi

CODESIGN_ID="${CODESIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')}"
if [[ -z "${CODESIGN_ID}" ]]; then
  echo "Set CODESIGN_ID to your signing identity"
  exit 1
fi

mkdir -p "${BUILD}"
cd "${BUILD}"
cmake -Wno-dev -DCODESIGN_ID="${CODESIGN_ID}" ..
make -j"$(sysctl -n hw.logicalcpu)"

echo ""
echo "Built: ${BUILD}/VoxaMicDevice/VoxaMic.driver"
echo "Install: sudo ${ROOT}/install.sh"
