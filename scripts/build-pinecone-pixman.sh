#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT_DIR}/scripts/rootfs/pinecone-pixman.c"
OUTPUT="${1:-${ROOT_DIR}/artifacts/linux-shell/out/libpinecone-pixman.so}"
SYSROOT="${PINECONE_SYSROOT:-}"
CLANG="${CLANG:-/opt/homebrew/opt/llvm/bin/clang}"
LLD="${LLD:-/opt/homebrew/opt/lld/bin/ld.lld}"

TEMP_SYSROOT=
if [[ -z "${SYSROOT}" ]]; then
  CACHE_DIR="${ROOT_DIR}/artifacts/alpine-packages/edge-aarch64"
  MUSL_DEV="$(find "${CACHE_DIR}" -maxdepth 1 -name 'musl-dev-*.apk' -print -quit)"
  if [[ -z "${MUSL_DEV}" ]]; then
    INDEX="${CACHE_DIR}/main-APKINDEX"
    [[ -s "${INDEX}" ]] || {
      echo 'missing Alpine main package index; stage graphical packages once first' >&2
      exit 1
    }
    MUSL_VERSION="$(awk '
      BEGIN { RS=""; FS="\n" }
      $0 ~ /(^|\n)P:musl-dev(\n|$)/ {
        for (line = 1; line <= NF; line++)
          if ($line ~ /^V:/) { print substr($line, 3); exit }
      }
    ' "${INDEX}")"
    [[ -n "${MUSL_VERSION}" ]] || {
      echo 'unable to resolve musl-dev from Alpine package index' >&2
      exit 1
    }
    MUSL_DEV="${CACHE_DIR}/musl-dev-${MUSL_VERSION}.apk"
    curl -fL --retry 3 -o "${MUSL_DEV}" \
      "https://dl-cdn.alpinelinux.org/alpine/edge/main/aarch64/musl-dev-${MUSL_VERSION}.apk"
  fi
  TEMP_SYSROOT="$(mktemp -d "${TMPDIR:-/tmp}/pinecone-musl.XXXXXX")"
  SYSROOT="${TEMP_SYSROOT}"
  bsdtar -xf "${MUSL_DEV}" -C "${SYSROOT}" \
    --exclude '.SIGN.RSA.*' --exclude .PKGINFO
fi
trap '[[ -n "${TEMP_SYSROOT}" ]] && rm -rf "${TEMP_SYSROOT}"' EXIT

mkdir -p "$(dirname "${OUTPUT}")"
[[ -f "${SYSROOT}/usr/include/dlfcn.h" ]] || {
  echo 'Alpine musl-dev sysroot is missing dlfcn.h' >&2
  exit 1
}
"${CLANG}" \
  --target=aarch64-linux-musl \
  --sysroot="${SYSROOT}" \
  -O3 -fPIC -fno-stack-protector \
  -Wall -Wextra -Werror \
  -c "${SOURCE}" -o "${OUTPUT}.o"
"${LLD}" -shared -soname libpinecone-pixman.so \
  --allow-shlib-undefined "${OUTPUT}.o" -o "${OUTPUT}"
rm -f "${OUTPUT}.o"

echo "Built Pinecone Pixman bridge: ${OUTPUT}"
