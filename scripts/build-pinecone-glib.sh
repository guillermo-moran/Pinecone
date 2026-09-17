#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/scripts/alpine/glib"
OUTPUT="$ROOT/artifacts/alpine-packages/pinecone-glib/aarch64"
INSTANCE="${PINECONE_GLIB_LIMA_INSTANCE:-pinecone-builder}"
mkdir -p "$OUTPUT"
cp "$ROOT/scripts/patches/glib-pinecone-mime-search.patch" "$PACKAGE_DIR/"
limactl start "$INSTANCE" >/dev/null
limactl shell "$INSTANCE" sudo apk add --no-cache alpine-sdk bash
USER_NAME="$(limactl shell "$INSTANCE" id -un)"
HOME_DIR="$(limactl shell "$INSTANCE" sh -lc 'printf %s "$HOME"')"
BUILD="$HOME_DIR/pinecone-glib-build"
limactl shell "$INSTANCE" sudo addgroup "$USER_NAME" abuild 2>/dev/null || true
limactl shell "$INSTANCE" sh -lc 'test -f ~/.abuild/abuild.conf || abuild-keygen -a -n'
KEY="$(limactl shell "$INSTANCE" sh -lc 'sed -n '\''s/^PACKAGER_PRIVKEY=//p'\'' ~/.abuild/abuild.conf | tr -d '\''"'\''')"
limactl shell "$INSTANCE" sudo cp "$KEY.pub" /etc/apk/keys/
limactl shell "$INSTANCE" mkdir -p "$BUILD"
limactl copy "$PACKAGE_DIR"/* "$INSTANCE:$BUILD/"
limactl shell "$INSTANCE" sudo -u "$USER_NAME" -g abuild sh -lc \
  "cd '$BUILD' && abuild -r -K"
if ! limactl shell "$INSTANCE" test -f "$BUILD/src/glib-2.88.3/gio/xdgmime/xdgmimecache.c"; then
  limactl shell "$INSTANCE" sudo -u "$USER_NAME" -g abuild sh -lc \
    "cd '$BUILD' && abuild -f prepare"
fi
limactl shell "$INSTANCE" bash "$ROOT/scripts/run-glib-mime-regressions.sh" \
  "$BUILD/src/glib-2.88.3"
PACKAGE="$(limactl shell "$INSTANCE" sh -lc \
  "find ~/packages -path '*/aarch64/glib-2.88.3-r1.apk' -print -quit")"
[[ -n "$PACKAGE" ]] || { echo 'GLib runtime package missing' >&2; exit 1; }
limactl copy "$INSTANCE:$PACKAGE" "$OUTPUT/"
INFO="$(bsdtar -xOf "$OUTPUT/glib-2.88.3-r1.apk" .PKGINFO)"
grep -qx 'pkgname = glib' <<<"$INFO"
grep -qx 'pkgver = 2.88.3-r1' <<<"$INFO"
grep -qx 'arch = aarch64' <<<"$INFO"
bsdtar -tf "$OUTPUT/glib-2.88.3-r1.apk" usr/lib/libgio-2.0.so.0.8800.3 >/dev/null
echo "Built and tested $OUTPUT/glib-2.88.3-r1.apk"
