#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/scripts/alpine/wlroots0.20"
OUTPUT_DIR="${ROOT_DIR}/artifacts/alpine-packages/pinecone-wlroots/aarch64"
INSTANCE="${PINECONE_WLROOTS_LIMA_INSTANCE:-pinecone-wlroots}"

mkdir -p "${OUTPUT_DIR}"
cp "${ROOT_DIR}/scripts/patches/wlroots-pinecone-0.20.2.patch" \
  "${PACKAGE_DIR}/wlroots-pinecone-0.20.2.patch"

if [[ "$(uname -s)" == "Linux" ]] && command -v abuild >/dev/null 2>&1; then
  cd "${PACKAGE_DIR}"
  abuild -r
  exit 0
fi

command -v limactl >/dev/null 2>&1 || {
  echo "Lima is required to build Alpine aarch64 packages on macOS" >&2
  exit 1
}

if ! limactl list --format '{{.Name}}' | grep -qx "${INSTANCE}"; then
  limactl start --name="${INSTANCE}" --cpus=6 --memory=8 --disk=20 \
    --mount="${ROOT_DIR}:w" --containerd=none --tty=false template:alpine
else
  limactl start "${INSTANCE}" >/dev/null
fi

limactl shell "${INSTANCE}" sudo sed -i 's#/v[0-9][0-9.]*#/edge#g' /etc/apk/repositories
limactl shell "${INSTANCE}" sudo apk update
limactl shell "${INSTANCE}" sudo apk add --no-cache alpine-sdk
GUEST_USER="$(limactl shell "${INSTANCE}" id -un)"
limactl shell "${INSTANCE}" sudo addgroup "${GUEST_USER}" abuild 2>/dev/null || true
limactl shell "${INSTANCE}" sh -lc \
  "test -f ~/.abuild/abuild.conf || abuild-keygen -a -n"
GUEST_PRIVATE_KEY="$(limactl shell "${INSTANCE}" sh -lc \
  "sed -n 's/^PACKAGER_PRIVKEY=//p' ~/.abuild/abuild.conf | tr -d '\"'")"
GUEST_PUBLIC_KEY="${GUEST_PRIVATE_KEY}.pub"
[[ -n "${GUEST_PUBLIC_KEY}" ]] || {
  echo "abuild public key was not generated" >&2
  exit 1
}
limactl shell "${INSTANCE}" sudo cp "${GUEST_PUBLIC_KEY}" /etc/apk/keys/
GUEST_HOME="$(limactl shell "${INSTANCE}" sh -lc 'printf %s "$HOME"')"
GUEST_BUILD_DIR="${GUEST_HOME}/pinecone-wlroots-build"
limactl shell "${INSTANCE}" mkdir -p "${GUEST_BUILD_DIR}"
limactl copy \
  "${PACKAGE_DIR}/APKBUILD" \
  "${PACKAGE_DIR}/e8c983808d8b98a71f991c16c24367494386958b.patch" \
  "${PACKAGE_DIR}/wlroots-pinecone-0.20.2.patch" \
  "${INSTANCE}:${GUEST_BUILD_DIR}/"
limactl shell "${INSTANCE}" sudo -u "${GUEST_USER}" -g abuild sh -lc \
  "cd '${GUEST_BUILD_DIR}' && abuild -r"

GUEST_PACKAGE="$(limactl shell "${INSTANCE}" sh -lc \
  "find ~/packages -path '*/aarch64/wlroots0.20-0.20.2-r4.apk' -print -quit")"
[[ -n "${GUEST_PACKAGE}" ]] || {
  echo "wlroots runtime package was not produced" >&2
  exit 1
}
limactl copy "${INSTANCE}:${GUEST_PACKAGE}" "${OUTPUT_DIR}/"

PACKAGE="${OUTPUT_DIR}/wlroots0.20-0.20.2-r4.apk"
INFO="$(bsdtar -xOf "${PACKAGE}" .PKGINFO)"
grep -qx 'pkgname = wlroots0.20' <<<"${INFO}"
grep -qx 'pkgver = 0.20.2-r4' <<<"${INFO}"
grep -qx 'arch = aarch64' <<<"${INFO}"
bsdtar -tf "${PACKAGE}" | grep -q '^usr/lib/libwlroots-0.20.so$'

echo "Built and verified ${PACKAGE}"
