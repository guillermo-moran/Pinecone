#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/scripts/alpine/phoc"
OUTPUT_DIR="${ROOT_DIR}/artifacts/alpine-packages/pinecone-phoc/aarch64"
INSTANCE="${PINECONE_WLROOTS_LIMA_INSTANCE:-pinecone-wlroots}"

mkdir -p "${OUTPUT_DIR}"
cp "${ROOT_DIR}/scripts/patches/phoc-pinecone-layout.patch" "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/scripts/patches/phoc-pinecone-interactions.patch" "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/scripts/patches/wlroots-pinecone-0.20.2.patch" \
  "${PACKAGE_DIR}/wlroots-pinecone-0.20.2.patch.embed"
for patch_name in wlroots-pinecone-dmabuf wlroots-pinecone-ownership wlroots-pinecone-shm-snapshot; do
  cp "${ROOT_DIR}/scripts/patches/${patch_name}.patch" \
    "${PACKAGE_DIR}/${patch_name}.patch.embed"
done

command -v limactl >/dev/null 2>&1 || {
  echo "Lima is required to build Alpine aarch64 packages on macOS" >&2
  exit 1
}
limactl start "${INSTANCE}" >/dev/null
limactl shell "${INSTANCE}" sudo apk add --no-cache alpine-sdk
# GNOME 51 changed the SONAME; build against the ABI in the pinned guest image.
limactl shell "${INSTANCE}" sudo apk add --no-cache \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.23/community \
  gnome-desktop-dev=44.5-r0
GUEST_USER="$(limactl shell "${INSTANCE}" id -un)"
limactl shell "${INSTANCE}" sudo addgroup "${GUEST_USER}" abuild 2>/dev/null || true
limactl shell "${INSTANCE}" sh -lc \
  "test -f ~/.abuild/abuild.conf || abuild-keygen -a -n"
GUEST_PRIVATE_KEY="$(limactl shell "${INSTANCE}" sh -lc \
  "sed -n 's/^PACKAGER_PRIVKEY=//p' ~/.abuild/abuild.conf | tr -d '\"'")"
limactl shell "${INSTANCE}" sudo cp "${GUEST_PRIVATE_KEY}.pub" /etc/apk/keys/
GUEST_HOME="$(limactl shell "${INSTANCE}" sh -lc 'printf %s "$HOME"')"
GUEST_BUILD_DIR="${GUEST_HOME}/pinecone-phoc-build"
limactl shell "${INSTANCE}" mkdir -p "${GUEST_BUILD_DIR}"
limactl copy "${PACKAGE_DIR}/APKBUILD" \
  "${PACKAGE_DIR}/phoc-pinecone-layout.patch" \
  "${PACKAGE_DIR}/phoc-pinecone-interactions.patch" \
  "${PACKAGE_DIR}/wlroots-pinecone-0.20.2.patch.embed" \
  "${PACKAGE_DIR}/wlroots-pinecone-dmabuf.patch.embed" \
  "${PACKAGE_DIR}/wlroots-pinecone-ownership.patch.embed" \
  "${PACKAGE_DIR}/wlroots-pinecone-shm-snapshot.patch.embed" \
  "${INSTANCE}:${GUEST_BUILD_DIR}/"
limactl shell "${INSTANCE}" sudo -u "${GUEST_USER}" -g abuild sh -lc \
  "cd '${GUEST_BUILD_DIR}' && abuild -r"

GUEST_PACKAGE="$(limactl shell "${INSTANCE}" sh -lc \
  "find ~/packages -path '*/aarch64/phoc-0.57.0-r8.apk' -print -quit")"
[[ -n "${GUEST_PACKAGE}" ]] || {
  echo "Pinecone Phoc runtime package was not produced" >&2
  exit 1
}
limactl copy "${INSTANCE}:${GUEST_PACKAGE}" "${OUTPUT_DIR}/"
PACKAGE="${OUTPUT_DIR}/phoc-0.57.0-r8.apk"
INFO="$(bsdtar -xOf "${PACKAGE}" .PKGINFO)"
grep -qx 'pkgname = phoc' <<<"${INFO}"
grep -qx 'pkgver = 0.57.0-r8' <<<"${INFO}"
grep -qx 'arch = aarch64' <<<"${INFO}"
bsdtar -tf "${PACKAGE}" | grep -q '^usr/bin/phoc$'
echo "Built and verified ${PACKAGE}"
