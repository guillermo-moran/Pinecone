#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/scripts/alpine/phosh"
OUTPUT_DIR="${ROOT_DIR}/artifacts/alpine-packages/pinecone-phosh/aarch64"
INSTANCE="${PINECONE_WLROOTS_LIMA_INSTANCE:-pinecone-wlroots}"

mkdir -p "${OUTPUT_DIR}"
cp "${ROOT_DIR}/scripts/patches/phosh-pinecone-startup.patch" "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/scripts/patches/phosh-pinecone-app-manifest.patch" "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/scripts/patches/phosh-pinecone-service-profile.patch" "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/scripts/patches/phosh-pinecone-launch-lifecycle.patch" "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/scripts/patches/phosh-pinecone-launcher.patch" "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/scripts/patches/phosh-pinecone-launcher-polish.patch" "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/scripts/patches/phosh-pinecone-light-lockscreen.patch" "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/scripts/rootfs/pinecone-gtk.css" "${PACKAGE_DIR}/pinecone-launcher.css"

command -v limactl >/dev/null 2>&1 || {
  echo "Lima is required to build Alpine aarch64 packages on macOS" >&2
  exit 1
}
limactl start "${INSTANCE}" >/dev/null
# Match the edge/aarch64 package set staged into Pinecone's guest image. Do
# not rely on mutable repository configuration left behind in a build VM.
limactl shell "${INSTANCE}" sudo sh -c \
  "printf '%s\n' \
    'https://dl-cdn.alpinelinux.org/alpine/edge/main' \
    'https://dl-cdn.alpinelinux.org/alpine/edge/community' \
    > /etc/apk/repositories"
limactl shell "${INSTANCE}" sudo apk update
# Keep bash outside abuild's temporary dependency transaction. Phosh depends
# on it at runtime, and abuild's repository-signing tail can invoke it after
# the temporary package set has already been removed.
limactl shell "${INSTANCE}" sudo apk add --no-cache alpine-sdk bash
# GNOME 51 changed the SONAME; build against the ABI in the pinned guest image.
limactl shell "${INSTANCE}" sudo apk add --no-cache \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.23/community \
  gnome-desktop-dev=44.5-r0
limactl shell "${INSTANCE}" sudo apk add --no-cache \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/community \
  evolution-data-server-dev=3.60.2-r2
GUEST_USER="$(limactl shell "${INSTANCE}" id -un)"
limactl shell "${INSTANCE}" sudo addgroup "${GUEST_USER}" abuild 2>/dev/null || true
limactl shell "${INSTANCE}" sh -lc \
  "test -f ~/.abuild/abuild.conf || abuild-keygen -a -n"
GUEST_PRIVATE_KEY="$(limactl shell "${INSTANCE}" sh -lc \
  "sed -n 's/^PACKAGER_PRIVKEY=//p' ~/.abuild/abuild.conf | tr -d '\"'")"
limactl shell "${INSTANCE}" sudo cp "${GUEST_PRIVATE_KEY}.pub" /etc/apk/keys/
GUEST_HOME="$(limactl shell "${INSTANCE}" sh -lc 'printf %s "$HOME"')"
GUEST_BUILD_DIR="${GUEST_HOME}/pinecone-phosh-build"
limactl shell "${INSTANCE}" mkdir -p "${GUEST_BUILD_DIR}"
limactl copy \
  "${PACKAGE_DIR}/APKBUILD" \
  "${PACKAGE_DIR}/phosh.trigger" \
  "${PACKAGE_DIR}/phosh-pinecone-startup.patch" \
  "${PACKAGE_DIR}/phosh-pinecone-app-manifest.patch" \
  "${PACKAGE_DIR}/phosh-pinecone-service-profile.patch" \
  "${PACKAGE_DIR}/phosh-pinecone-launch-lifecycle.patch" \
  "${PACKAGE_DIR}/phosh-pinecone-launcher.patch" \
  "${PACKAGE_DIR}/phosh-pinecone-launcher-polish.patch" \
  "${PACKAGE_DIR}/phosh-pinecone-light-lockscreen.patch" \
  "${PACKAGE_DIR}/pinecone-launcher.css" \
  "${INSTANCE}:${GUEST_BUILD_DIR}/"
# Build dependencies are distinct from the session's runtime dependency closure.
# Installing edge's current session/keyboard here would force a newer GNOME ABI.
# The rootfs staging validator checks runtime dependencies against the guest pins.
limactl shell "${INSTANCE}" sudo -u "${GUEST_USER}" -g abuild sh -lc \
  "set -e
   cd '${GUEST_BUILD_DIR}'
   . ./APKBUILD
   sudo apk add --no-cache --virtual .pinecone-phosh-build \$makedepends \$checkdepends
   trap 'sudo apk del .pinecone-phosh-build' EXIT
   abuild -d"

GUEST_PACKAGE="$(limactl shell "${INSTANCE}" sh -lc \
  "find ~/packages -path '*/aarch64/phosh-0.57.0-r8.apk' -print -quit")"
[[ -n "${GUEST_PACKAGE}" ]] || {
  echo "Pinecone Phosh runtime package was not produced" >&2
  exit 1
}
limactl copy "${INSTANCE}:${GUEST_PACKAGE}" "${OUTPUT_DIR}/"
PACKAGE="${OUTPUT_DIR}/phosh-0.57.0-r8.apk"
INFO="$(bsdtar -xOf "${PACKAGE}" .PKGINFO)"
grep -qx 'pkgname = phosh' <<<"${INFO}"
grep -qx 'pkgver = 0.57.0-r8' <<<"${INFO}"
grep -qx 'arch = aarch64' <<<"${INFO}"
bsdtar -tf "${PACKAGE}" usr/libexec/phosh >/dev/null
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pinecone-phosh-verify.XXXXXX")"
trap 'rm -rf "${VERIFY_DIR}"' EXIT
bsdtar -xf "${PACKAGE}" -C "${VERIFY_DIR}" usr/libexec/phosh
PHOSH_BINARY="${VERIFY_DIR}/usr/libexec/phosh"
grep -aFq 'PINECONE_PHOSH_PROFILE' "${PHOSH_BINARY}"
grep -aFq 'PINECONE_PHOSH_APP_MANIFEST' "${PHOSH_BINARY}"
grep -aFq 'Pinecone app manifest loaded' "${PHOSH_BINARY}"
grep -aFq 'PINECONE_PHOSH_LAUNCHER' "${PHOSH_BINARY}"
grep -aFq 'pinecone navigation' "${PHOSH_BINARY}"
grep -aFq 'pinecone-app-label' "${PHOSH_BINARY}"
grep -aFq 'Pinecone lightweight lockscreen enabled' "${PHOSH_BINARY}"
mkdir -p "${ROOT_DIR}/artifacts/launcher-preview"
for width in 320 360 480; do
  limactl copy "${INSTANCE}:${GUEST_BUILD_DIR}/launcher-screenshots/launcher-${width}.png" \
    "${ROOT_DIR}/artifacts/launcher-preview/"
done
echo "Built and verified ${PACKAGE}"
