#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT_DIR}/scripts/rootfs/pinecone-session-launcher.c"
OUTPUT="${1:-${ROOT_DIR}/artifacts/linux-shell/out/pinecone-session-launcher}"
CACHE_DIR="${ROOT_DIR}/artifacts/alpine-packages/edge-aarch64"
CLANG="${CLANG:-/opt/homebrew/opt/llvm/bin/clang}"
LLD="${LLD:-/opt/homebrew/opt/lld/bin/ld.lld}"

MUSL="$(find "${CACHE_DIR}" -maxdepth 1 -name 'musl-[0-9]*.apk' -print -quit)"
MUSL_DEV="$(find "${CACHE_DIR}" -maxdepth 1 -name 'musl-dev-*.apk' -print -quit)"
[[ -n "${MUSL}" && -n "${MUSL_DEV}" ]] || {
  echo 'musl and musl-dev Alpine packages are required' >&2
  exit 1
}

SYSROOT="$(mktemp -d "${TMPDIR:-/tmp}/pinecone-launcher.XXXXXX")"
trap 'rm -rf "${SYSROOT}"' EXIT
bsdtar -xf "${MUSL}" -C "${SYSROOT}" --exclude '.SIGN.RSA.*' --exclude .PKGINFO
bsdtar -xf "${MUSL_DEV}" -C "${SYSROOT}" --exclude '.SIGN.RSA.*' --exclude .PKGINFO
mkdir -p "$(dirname "${OUTPUT}")"

OBJECT="${OUTPUT}.o"
"${CLANG}" \
  --target=aarch64-linux-musl \
  --sysroot="${SYSROOT}" \
  -O3 -fno-stack-protector \
  -Wall -Wextra -Werror \
  -c "${SOURCE}" -o "${OBJECT}"
"${LLD}" -static -o "${OUTPUT}" \
  "${SYSROOT}/usr/lib/crt1.o" \
  "${SYSROOT}/usr/lib/crti.o" \
  "${OBJECT}" \
  --start-group "${SYSROOT}/usr/lib/libc.a" --end-group \
  "${SYSROOT}/usr/lib/crtn.o"
rm -f "${OBJECT}"

echo "Built Pinecone session launcher: ${OUTPUT}"
