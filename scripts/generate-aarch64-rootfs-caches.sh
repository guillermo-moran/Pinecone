#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${1:?usage: generate-aarch64-rootfs-caches.sh ROOTFS_DIR}"
INSTANCE="${PINECONE_CACHE_LIMA_INSTANCE:-pinecone-wlroots}"

[[ -x "${ROOTFS}/usr/bin/fc-cache" ]] || {
  echo "missing aarch64 fc-cache in ${ROOTFS}" >&2
  exit 1
}
[[ -x "${ROOTFS}/usr/bin/gdk-pixbuf-query-loaders" ]] || {
  echo "missing aarch64 gdk-pixbuf-query-loaders in ${ROOTFS}" >&2
  exit 1
}
mkdir -p "${ROOTFS}/var/cache/fontconfig"
chmod 0755 "${ROOTFS}/var/cache/fontconfig"

generate_in_chroot() {
  local rootfs="$1"
  chroot "${rootfs}" /usr/bin/fc-cache --system-only --really-force
  mkdir -p "${rootfs}/usr/lib/gdk-pixbuf-2.0/2.10.0"
  chroot "${rootfs}" /usr/bin/gdk-pixbuf-query-loaders > \
    "${rootfs}/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
}

if [[ "$(uname -s)" == "Linux" ]]; then
  if [[ "$(id -u)" == "0" ]]; then
    generate_in_chroot "${ROOTFS}"
  else
    sudo bash -c "$(declare -f generate_in_chroot); generate_in_chroot '$ROOTFS'"
  fi
  exit 0
fi

command -v limactl >/dev/null 2>&1 || {
  echo "Lima is required to generate aarch64 runtime caches on macOS" >&2
  exit 1
}
limactl start "${INSTANCE}" >/dev/null

# Existing Lima instances can expose the workspace read-only. Stage one tar
# archive on Lima's writable disk, run the exact binaries that will ship in
# the image, and copy back only the generated caches.
HOST_ROOTFS_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/pinecone-rootfs-cache.tar.XXXXXX")"
HOST_CACHE_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/pinecone-generated-cache.tar.XXXXXX")"
GUEST_WORK="$(limactl shell "${INSTANCE}" mktemp -d /tmp/pinecone-rootfs-cache.XXXXXX)"
GUEST_ROOT="${GUEST_WORK}/root"
GUEST_ROOTFS_ARCHIVE="${GUEST_WORK}/rootfs.tar"
GUEST_CACHE_ARCHIVE="${GUEST_WORK}/generated-cache.tar"
cleanup() {
  rm -f "${HOST_ROOTFS_ARCHIVE}" "${HOST_CACHE_ARCHIVE}"
  limactl shell "${INSTANCE}" sudo rm -rf "${GUEST_WORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

COPYFILE_DISABLE=1 bsdtar --no-xattrs -cf "${HOST_ROOTFS_ARCHIVE}" \
  -C "${ROOTFS}" .
limactl copy "${HOST_ROOTFS_ARCHIVE}" "${INSTANCE}:${GUEST_ROOTFS_ARCHIVE}"
limactl shell "${INSTANCE}" sudo mkdir -p "${GUEST_ROOT}"
limactl shell "${INSTANCE}" sudo tar -xf "${GUEST_ROOTFS_ARCHIVE}" -C "${GUEST_ROOT}"
limactl shell "${INSTANCE}" sudo chroot "${GUEST_ROOT}" \
  /usr/bin/fc-cache --system-only --really-force
limactl shell "${INSTANCE}" sudo mkdir -p \
  "${GUEST_ROOT}/usr/lib/gdk-pixbuf-2.0/2.10.0"
limactl shell "${INSTANCE}" sudo sh -c \
  "chroot '$GUEST_ROOT' /usr/bin/gdk-pixbuf-query-loaders > '$GUEST_ROOT/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache'"
limactl shell "${INSTANCE}" sudo tar -cf "${GUEST_CACHE_ARCHIVE}" \
  -C "${GUEST_ROOT}" var/cache/fontconfig \
  usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
limactl copy "${INSTANCE}:${GUEST_CACHE_ARCHIVE}" "${HOST_CACHE_ARCHIVE}"
bsdtar -xf "${HOST_CACHE_ARCHIVE}" -C "${ROOTFS}"

find "${ROOTFS}/var/cache/fontconfig" -type f -name '*cache-*' -print -quit | grep -q .
test -s "${ROOTFS}/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
