#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${1:?usage: patch-wlroots-pinecone.sh WLROOTS_SOURCE_DIR}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="${ROOT_DIR}/scripts/patches/wlroots-pinecone-0.20.2.patch"

[[ -d "${SOURCE_DIR}/types/buffer" && -d "${SOURCE_DIR}/types/output" ]] || {
  echo "not a wlroots source tree: ${SOURCE_DIR}" >&2
  exit 2
}

VERSION="$(git -C "${SOURCE_DIR}" describe --tags --exact-match 2>/dev/null || true)"
[[ "${VERSION}" == "0.20.2" ]] || {
  echo "expected wlroots tag 0.20.2, found ${VERSION:-unknown}" >&2
  exit 2
}

patch --batch --forward -d "${SOURCE_DIR}" -p1 < "${PATCH_FILE}"
echo "Applied Pinecone wlroots integration to ${SOURCE_DIR}"
