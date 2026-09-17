#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="${ROOT_DIR}/scripts/patches/gnome-control-center-pinecone-prewarm.patch"
OUTPUT_DIR="${ROOT_DIR}/artifacts/alpine-packages/pinecone-gnome-control-center/aarch64"
INSTANCE="${PINECONE_SETTINGS_LIMA_INSTANCE:-pinecone-builder}"
APORTS_COMMIT="${PINECONE_SETTINGS_APORTS_COMMIT:-811833d5f62f82be50bf103ff8325c70970d03b6}"
PACKAGE_VERSION="50.4-r2"

mkdir -p "${OUTPUT_DIR}"

command -v limactl >/dev/null 2>&1 || {
  echo "Lima is required to build Pinecone's aarch64 GNOME Settings package" >&2
  exit 1
}

limactl start "${INSTANCE}" >/dev/null
limactl shell "${INSTANCE}" sudo sh -c \
  "printf '%s\n' \
    'https://dl-cdn.alpinelinux.org/alpine/edge/main' \
    'https://dl-cdn.alpinelinux.org/alpine/edge/community' \
    > /etc/apk/repositories"
limactl shell "${INSTANCE}" sudo apk update
limactl shell "${INSTANCE}" sudo apk add --no-cache alpine-sdk bash git

GUEST_USER="$(limactl shell "${INSTANCE}" id -un)"
GUEST_HOME="$(limactl shell "${INSTANCE}" sh -lc 'printf %s "$HOME"')"
GUEST_APORTS="${GUEST_HOME}/pinecone-aports"
GUEST_BUILD="${GUEST_HOME}/pinecone-gnome-control-center-build"

limactl shell "${INSTANCE}" sudo addgroup "${GUEST_USER}" abuild 2>/dev/null || true
limactl shell "${INSTANCE}" sh -lc \
  "test -f ~/.abuild/abuild.conf || abuild-keygen -a -n"
GUEST_PRIVATE_KEY="$(limactl shell "${INSTANCE}" sh -lc \
  "sed -n 's/^PACKAGER_PRIVKEY=//p' ~/.abuild/abuild.conf | tr -d '\"'")"
limactl shell "${INSTANCE}" sudo cp "${GUEST_PRIVATE_KEY}.pub" /etc/apk/keys/

if ! limactl shell "${INSTANCE}" test -d "${GUEST_APORTS}/.git"; then
  limactl shell "${INSTANCE}" git clone --depth=1 --filter=blob:none --no-checkout \
    https://gitlab.alpinelinux.org/alpine/aports.git "${GUEST_APORTS}"
fi
limactl shell "${INSTANCE}" git -C "${GUEST_APORTS}" fetch --depth=1 origin "${APORTS_COMMIT}"
limactl shell "${INSTANCE}" git -C "${GUEST_APORTS}" checkout --detach --force "${APORTS_COMMIT}"
limactl shell "${INSTANCE}" rm -rf "${GUEST_BUILD}"
limactl shell "${INSTANCE}" cp -R \
  "${GUEST_APORTS}/community/gnome-control-center" "${GUEST_BUILD}"
limactl copy "${PATCH}" \
  "${INSTANCE}:${GUEST_BUILD}/gnome-control-center-pinecone-prewarm.patch"

limactl shell "${INSTANCE}" grep -qx 'pkgver=50.4' "${GUEST_BUILD}/APKBUILD"
limactl shell "${INSTANCE}" grep -qx 'pkgrel=0' "${GUEST_BUILD}/APKBUILD"
limactl shell "${INSTANCE}" sed -i 's/^pkgrel=0$/pkgrel=2/' "${GUEST_BUILD}/APKBUILD"
limactl shell "${INSTANCE}" sh -c \
  "awk '{ print; if (\$0 ~ /^source=\"/) print \"\\tgnome-control-center-pinecone-prewarm.patch\" }' \
    '${GUEST_BUILD}/APKBUILD' > '${GUEST_BUILD}/APKBUILD.pinecone'"
limactl shell "${INSTANCE}" mv \
  "${GUEST_BUILD}/APKBUILD.pinecone" "${GUEST_BUILD}/APKBUILD"
limactl shell "${INSTANCE}" sudo -u "${GUEST_USER}" -g abuild sh -lc \
  "cd '${GUEST_BUILD}' && abuild checksum && abuild -r"

GUEST_PACKAGE="$(limactl shell "${INSTANCE}" sh -lc \
  "find ~/packages -path '*/aarch64/gnome-control-center-${PACKAGE_VERSION}.apk' -print -quit")"
[[ -n "${GUEST_PACKAGE}" ]] || {
  echo "Pinecone GNOME Settings runtime package was not produced" >&2
  exit 1
}
limactl copy "${INSTANCE}:${GUEST_PACKAGE}" "${OUTPUT_DIR}/"

PACKAGE="${OUTPUT_DIR}/gnome-control-center-${PACKAGE_VERSION}.apk"
INFO="$(bsdtar -xOf "${PACKAGE}" .PKGINFO)"
grep -qx 'pkgname = gnome-control-center' <<<"${INFO}"
grep -qx "pkgver = ${PACKAGE_VERSION}" <<<"${INFO}"
grep -qx 'arch = aarch64' <<<"${INFO}"
bsdtar -tf "${PACKAGE}" usr/bin/gnome-control-center >/dev/null

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pinecone-settings-verify.XXXXXX")"
trap 'rm -rf "${VERIFY_DIR}"' EXIT
bsdtar -xf "${PACKAGE}" -C "${VERIFY_DIR}" usr/bin/gnome-control-center
grep -aFq 'pinecone-prewarm' "${VERIFY_DIR}/usr/bin/gnome-control-center"
grep -aFq 'Pinecone Settings prewarm ready' \
  "${VERIFY_DIR}/usr/bin/gnome-control-center"

echo "Built and verified ${PACKAGE}"
