#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="${ROOT_DIR}/scripts/patches/musl-pinecone-startup-symbol-cache.patch"
OUTPUT_DIR="${ROOT_DIR}/artifacts/alpine-packages/pinecone-musl/aarch64"
INSTANCE="${PINECONE_MUSL_LIMA_INSTANCE:-pinecone-builder}"
APORTS_COMMIT="${PINECONE_APORTS_COMMIT:-11bd4e3a5442ee6c0156c1a9fd290fb49b2f561a}"
PACKAGE_VERSION="1.2.6-r6"

mkdir -p "${OUTPUT_DIR}"

if [[ "$(uname -s)" == "Linux" ]] && command -v abuild >/dev/null 2>&1; then
  echo "Run this builder from macOS so it can use the pinned clean aports tree." >&2
  exit 2
fi

command -v limactl >/dev/null 2>&1 || {
  echo "Lima is required to build the Pinecone aarch64 musl package" >&2
  exit 1
}

limactl start "${INSTANCE}" >/dev/null
limactl shell "${INSTANCE}" sudo sh -c \
  "printf '%s\n' \
    'https://dl-cdn.alpinelinux.org/alpine/edge/main' \
    'https://dl-cdn.alpinelinux.org/alpine/edge/community' \
    > /etc/apk/repositories"
limactl shell "${INSTANCE}" sudo apk update
# Keep the build shell and source-control tooling outside abuild's temporary
# dependency transaction so package signing remains deterministic.
limactl shell "${INSTANCE}" sudo apk add --no-cache alpine-sdk bash git

GUEST_USER="$(limactl shell "${INSTANCE}" id -un)"
GUEST_HOME="$(limactl shell "${INSTANCE}" sh -lc 'printf %s "$HOME"')"
GUEST_APORTS="${GUEST_HOME}/pinecone-aports"
GUEST_BUILD="${GUEST_HOME}/pinecone-musl-build"

limactl shell "${INSTANCE}" sudo addgroup "${GUEST_USER}" abuild 2>/dev/null || true
limactl shell "${INSTANCE}" sh -lc \
  "test -f ~/.abuild/abuild.conf || abuild-keygen -a -n"
GUEST_PRIVATE_KEY="$(limactl shell "${INSTANCE}" sh -lc \
  "sed -n 's/^PACKAGER_PRIVKEY=//p' ~/.abuild/abuild.conf | tr -d '\"'")"
GUEST_PUBLIC_KEY="${GUEST_PRIVATE_KEY}.pub"
limactl shell "${INSTANCE}" sudo cp "${GUEST_PUBLIC_KEY}" /etc/apk/keys/

if ! limactl shell "${INSTANCE}" test -d "${GUEST_APORTS}/.git"; then
  limactl shell "${INSTANCE}" git clone --depth=1 --filter=blob:none --no-checkout \
    https://gitlab.alpinelinux.org/alpine/aports.git "${GUEST_APORTS}"
fi
limactl shell "${INSTANCE}" git -C "${GUEST_APORTS}" fetch --depth=1 origin "${APORTS_COMMIT}"
limactl shell "${INSTANCE}" git -C "${GUEST_APORTS}" checkout --detach --force "${APORTS_COMMIT}"
limactl shell "${INSTANCE}" rm -rf "${GUEST_BUILD}"
limactl shell "${INSTANCE}" cp -R "${GUEST_APORTS}/main/musl" "${GUEST_BUILD}"
limactl copy "${PATCH}" "${INSTANCE}:${GUEST_BUILD}/pinecone-startup-symbol-cache.patch"

limactl shell "${INSTANCE}" sed -i 's/^pkgrel=2$/pkgrel=6/' "${GUEST_BUILD}/APKBUILD"
limactl shell "${INSTANCE}" sed -i \
  's#https://musl.libc.org/releases/#https://distfiles.alpinelinux.org/distfiles/edge/#' \
  "${GUEST_BUILD}/APKBUILD"
limactl shell "${INSTANCE}" sed -i \
  '/CVE-2026-40200.patch/a pinecone-startup-symbol-cache.patch' \
  "${GUEST_BUILD}/APKBUILD"
limactl shell "${INSTANCE}" sudo -u "${GUEST_USER}" -g abuild sh -lc \
  "cd '${GUEST_BUILD}' && abuild checksum && abuild -r"

GUEST_PACKAGE="$(limactl shell "${INSTANCE}" sh -lc \
  "find ~/packages -path '*/aarch64/musl-${PACKAGE_VERSION}.apk' -print -quit")"
[[ -n "${GUEST_PACKAGE}" ]] || {
  echo "Pinecone musl runtime package was not produced" >&2
  exit 1
}
limactl copy "${INSTANCE}:${GUEST_PACKAGE}" "${OUTPUT_DIR}/"

PACKAGE="${OUTPUT_DIR}/musl-${PACKAGE_VERSION}.apk"
INFO="$(bsdtar -xOf "${PACKAGE}" .PKGINFO)"
grep -qx 'pkgname = musl' <<<"${INFO}"
grep -qx "pkgver = ${PACKAGE_VERSION}" <<<"${INFO}"
grep -qx 'arch = aarch64' <<<"${INFO}"
bsdtar -tf "${PACKAGE}" lib/ld-musl-aarch64.so.1 >/dev/null

echo "Built and verified ${PACKAGE}"
