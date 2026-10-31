#!/bin/sh
# Build-only: no dependency installation, runtime deployment, or image changes.
set -eu
if [ "$#" -ne 2 ]; then
  echo 'usage: sh build-sourceview.sh NEW-WORK-DIRECTORY GTKSOURCEVIEW-5.20.0-TAR.XZ' >&2
  exit 2
fi
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || {
  echo 'Linux/aarch64 build environment required' >&2; exit 1;
}
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
expected=d0d25ab7098d6626bde49bbd5c29986838f0958cd3e31b5cab74016eb37a4caea3351be9ce4268464a8d1cb42b10b698aa819b215f652c8c97382e0900df7893
actual=$(sha512sum "$2")
[ "${actual%% *}" = "$expected" ] || { echo 'source hash mismatch' >&2; exit 1; }
pkg-config --exists gtk4 libxml-2.0 libpcre2-8 fribidi fontconfig pangoft2
mkdir "$1"
work=$(CDPATH= cd -- "$1" && pwd)
tar -xf "$2" -C "$work"
source="$work/gtksourceview-5.20.0"
python3 "$src/make-patch.py" sourceview "$source" >"$work/sourceview-trace.patch"
patch --batch --fuzz=0 -p1 -d "$source" -i "$work/sourceview-trace.patch"
sh "$src/build-trace.sh" "$work/runtime"
cc -std=c11 -O2 -g -Wall -Wextra -Werror -fPIC -shared \
  $(pkg-config --cflags gtk4) "$src/trace-commit.c" \
  $(pkg-config --libs gtk4) -ldl -L"$work/runtime" -lpinecone-text-trace \
  '-Wl,-rpath,$ORIGIN' -o "$work/runtime/libpinecone-text-commit.so"
export CFLAGS="${CFLAGS:--O2 -g -fno-plt} -I$work/runtime"
export LDFLAGS="${LDFLAGS:-} -L$work/runtime -lpinecone-text-trace"
meson setup "$work/build" "$source" --prefix=/usr --libdir=lib \
  --buildtype=plain --wrap-mode=nofallback -Db_lto=true \
  -Dbuild-testsuite=false -Dintrospection=disabled -Dvapi=false -Ddocumentation=false
ninja -C "$work/build" -j "${PINECONE_BUILD_JOBS:-2}" gtksourceview/libgtksourceview-5.so.0.0.0
mkdir "$work/artifacts"
cp "$work/build/gtksourceview/libgtksourceview-5.so.0.0.0" "$work/artifacts/libgtksourceview-5.so.0"
cp "$work/runtime/libpinecone-text-trace.so" "$work/runtime/libpinecone-text-commit.so" "$work/artifacts/"
readelf -d "$work/artifacts/libgtksourceview-5.so.0" >"$work/dependencies.txt"
grep -q 'NEEDED.*libpinecone-text-trace.so' "$work/dependencies.txt"
pkg-config --modversion gtk4 glib-2.0 pango >"$work/build-versions.txt"
sha256sum "$work/artifacts/"*.so* >"$work/SHA256SUMS"
printf 'Private artifacts (not installed): %s/artifacts\n' "$work"
