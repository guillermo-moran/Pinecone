#!/usr/bin/env bash
# Linux/aarch64 only. Produces a diagnostic library, never a production overlay.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=${1:?usage: build-gtk-frame-diagnostic.sh NEW-WORK-DIRECTORY SOURCE-TARBALL}
ARCHIVE=${2:?verified upstream GTK 4.22.4 tarball required}
[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || {
  echo 'Run in the Alpine aarch64 builder' >&2; exit 1;
}
EXPECTED=f474174c27fec97b26809ae28ded2923f37e82fd25783ce31bbee40a99a02e5f9ce517583f0e499d91289e6b0ebae8e2dc249cba721d827ee35c7b867378797d
[[ $(sha512sum "$ARCHIVE" | cut -d ' ' -f1) == "$EXPECTED" ]] || {
  echo 'GTK source checksum mismatch' >&2; exit 1;
}
mkdir "$WORK"
tar -xf "$ARCHIVE" -C "$WORK"
SOURCE="$WORK/gtk-4.22.4"
python3 "$ROOT/scripts/test-gtk-frame-patch.py" "$SOURCE"
patch --batch --fuzz=0 -p1 -d "$SOURCE" \
  -i "$ROOT/scripts/patches/gtk4-frame-profile.patch"
# Alpine's 4.22.4-r0 patch only changes a Vulkan null handle on 32-bit hosts.
# aarch64 builds retain upstream behavior. Preserve all runtime backends.
export CFLAGS="${CFLAGS:--O2 -g -fno-plt}"
meson setup "$WORK/build" "$SOURCE" --prefix=/usr --libdir=lib \
  --buildtype=plain --wrap-mode=nofallback \
  -Dbroadway-backend=true -Dprint-cups=enabled \
  -Ddocumentation=false -Dman-pages=false -Dintrospection=disabled \
  -Dbuild-tests=false -Dbuild-testsuite=false -Dbuild-demos=false \
  -Dbuild-examples=false
ninja -C "$WORK/build" -j "${PINECONE_BUILD_JOBS:-4}" gtk/libgtk-4.so.1.2200.4
LIBRARY="$WORK/build/gtk/libgtk-4.so.1.2200.4"
readelf -Ws "$LIBRARY" | grep 'WEAK.*UND.*pinecone_gtk_frame_mark'
readelf -d "$LIBRARY"
pkg-config --modversion glib-2.0 pango cairo graphene-1.0
read -r -a GTK_CFLAGS <<<"$(pkg-config --cflags gtk4)"
read -r -a GTK_LIBS <<<"$(pkg-config --libs gtk4)"
cc -O2 -Wall -Wextra -Werror -Wl,--export-dynamic "${GTK_CFLAGS[@]}" \
  "$ROOT/scripts/gtk-private-hook-regression.c" -L"$WORK/build/gtk" \
  "${GTK_LIBS[@]}" -o "$WORK/private-hook-test"
LD_LIBRARY_PATH="$WORK/build/gtk" "$WORK/private-hook-test"
sha256sum "$LIBRARY"
printf 'Diagnostic library: %s\n' "$LIBRARY"
