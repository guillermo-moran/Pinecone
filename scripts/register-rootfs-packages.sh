#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == --worker ]]; then
  MANIFEST="${2:?missing archive manifest}"
  OUTPUT="${3:?missing output archive}"
  WORK="$(mktemp -d /tmp/pinecone-apk-db.XXXXXX)"
  trap 'rm -rf "$WORK"' EXIT
  mkdir -p "$WORK/root/etc/apk/keys" "$WORK/root/usr/share/pinecone" \
    "$WORK/root/usr/bin" "$WORK/root/usr/sbin" "$WORK/root/usr/lib"
  cp /etc/apk/keys/*.pub "$WORK/root/etc/apk/keys/"
  # Only public build-signing keys enter the guest. APK verifies every archive;
  # an unknown signer or an inconsistent dependency closure aborts the build.
  find "$ROOT/artifacts/alpine-packages" -name '*.rsa.pub' -exec cp '{}' "$WORK/root/etc/apk/keys/" \;
  archives=() pins=()
  while IFS='|' read -r archive package version; do
    [[ -f "$archive" && -n "$package" && -n "$version" ]] || exit 1
    archives+=("$archive")
    pins+=("$package=$version")
  done < "$MANIFEST"
  (( ${#archives[@]} > 0 ))
  options=(--root "$WORK/root" --keys-dir "$WORK/root/etc/apk/keys"
           --repositories-file /dev/null --no-network --no-scripts)
  apk "${options[@]}" add --initdb "${archives[@]}"
  apk "${options[@]}" add --virtual .pinecone-platform "${pins[@]}"
  # A single platform metapackage keeps the shipped runtime intact while new
  # user packages remain ordinary, removable world entries.
  grep '^\.pinecone-platform=' "$WORK/root/etc/apk/world" > "$WORK/world"
  mv "$WORK/world" "$WORK/root/etc/apk/world"
  printf '%s\n' "${pins[@]}" | sort -u > "$WORK/root/usr/share/pinecone/platform-packages.txt"
  apk "${options[@]}" fix --simulate
  # The initramfs is usr-merged, but some pinned APKs still contain /lib.
  # Keep the database independent of that layout; the host installs it at the
  # guest APK's canonical /lib/apk/db path after extraction is finished.
  cp -a "$WORK/root/lib/apk/db" "$WORK/root/apk-db"
  tar -C "$WORK/root" -cf "$OUTPUT" etc/apk/world etc/apk/keys apk-db \
    usr/share/pinecone/platform-packages.txt
  chmod 0644 "$OUTPUT"
  exit 0
fi

DEST="${1:?usage: register-rootfs-packages.sh ROOTFS MANIFEST}"
MANIFEST="${2:?missing archive manifest}"
INSTANCE="${PINECONE_CACHE_LIMA_INSTANCE:-pinecone-builder}"
ARCHIVE="$(mktemp /tmp/pinecone-apk-db-output.XXXXXX)"
EXTRACT="$(mktemp -d /tmp/pinecone-apk-db-extract.XXXXXX)"
REMOTE=""
cleanup() {
  rm -f "$ARCHIVE"
  rm -rf "$EXTRACT"
  if [[ -n "$REMOTE" ]]; then
    limactl shell --shell /bin/sh "$INSTANCE" rm -f "$REMOTE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
if [[ "$(uname -s)" == Linux ]]; then
  if [[ "$(id -u)" == 0 ]]; then
    bash "$0" --worker "$MANIFEST" "$ARCHIVE"
  else
    sudo bash "$0" --worker "$MANIFEST" "$ARCHIVE"
  fi
else
  REMOTE="$(limactl shell --shell /bin/sh "$INSTANCE" mktemp /tmp/pinecone-apk-db-output.XXXXXX)"
  limactl shell --shell /bin/sh "$INSTANCE" sudo bash \
    "$ROOT/scripts/register-rootfs-packages.sh" --worker "$MANIFEST" "$REMOTE"
  limactl copy "$INSTANCE:$REMOTE" "$ARCHIVE"
fi
bsdtar -xf "$ARCHIVE" -C "$EXTRACT"
mkdir -p "$DEST/lib/apk/db" "$DEST/etc/apk/keys" "$DEST/usr/share/pinecone"
cp -R "$EXTRACT/apk-db/." "$DEST/lib/apk/db/"
cp -R "$EXTRACT/etc/apk/keys/." "$DEST/etc/apk/keys/"
cp "$EXTRACT/etc/apk/world" "$DEST/etc/apk/world"
cp "$EXTRACT/usr/share/pinecone/platform-packages.txt" "$DEST/usr/share/pinecone/"
test -s "$DEST/lib/apk/db/installed"
test -s "$DEST/usr/share/pinecone/platform-packages.txt"
echo 'Registered verified APK packages and pinned the Pinecone platform.'
