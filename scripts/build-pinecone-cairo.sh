#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/artifacts/linux-shell/out/pinecone-cairo}"
if [[ "$(uname -s)" != Linux ]]; then
    # Use the existing builder only; never start a VM or install dependencies.
    INSTANCE="${PINECONE_CAIRO_LIMA_INSTANCE:-pinecone-builder}"
    mkdir -p "$OUTPUT" "$ROOT/artifacts/cairo-source"
    if [[ ! -f "$ROOT/artifacts/cairo-source/cairo-1.18.4.tar.xz" ]]; then
        curl --fail --location https://www.cairographics.org/releases/cairo-1.18.4.tar.xz \
            -o "$ROOT/artifacts/cairo-source/cairo-1.18.4.tar.xz"
    fi
    REMOTE_OUTPUT="$(limactl shell "$INSTANCE" mktemp -d /tmp/pinecone-cairo-runtime.XXXXXX)"
    limactl shell "$INSTANCE" \
        env "PINECONE_CAIRO_SYSROOT=${PINECONE_CAIRO_SYSROOT:-}" \
        bash "$ROOT/scripts/build-pinecone-cairo.sh" "$REMOTE_OUTPUT"
    for library in cairo cairo-gobject cairo-script-interpreter; do
        file="lib$library.so.2.11804.4"
        limactl copy "$INSTANCE:$REMOTE_OUTPUT/$file" "$OUTPUT/$file"
        ln -sfn "$file" "$OUTPUT/lib$library.so.2"
    done
    limactl copy "$INSTANCE:$REMOTE_OUTPUT/manifest.json" "$OUTPUT/manifest.json"
    python3 "$ROOT/scripts/cairo-runtime-manifest.py" verify "$OUTPUT"
    echo "Cairo runtime overlay: $OUTPUT"
    exit 0
fi
[[ "$(uname -m)" == aarch64 ]] || { echo 'An aarch64 Linux builder is required' >&2; exit 1; }
VERSION=1.18.4
ARCHIVE="$ROOT/artifacts/cairo-source/cairo-$VERSION.tar.xz"
SHA512=863679f817ed67dc2c916c035d740916e27e7e69c04fca63936e37d274e7f4c79848d16c8f7c481798864602e8847c489f698df89b785cbc576c925dbd513316
mkdir -p "$(dirname "$ARCHIVE")" "$OUTPUT"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location "https://www.cairographics.org/releases/cairo-$VERSION.tar.xz" -o "$ARCHIVE"
fi
[[ "$(sha512sum "$ARCHIVE" | awk '{print $1}')" == "$SHA512" ]]
WORK="$(mktemp -d /tmp/pinecone-cairo-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
STOCK_LIBDIR=/usr/lib
if [[ -n "${PINECONE_CAIRO_SYSROOT:-}" ]]; then
    export PKG_CONFIG_SYSROOT_DIR="$PINECONE_CAIRO_SYSROOT"
    export PKG_CONFIG_LIBDIR="$PINECONE_CAIRO_SYSROOT/usr/lib/pkgconfig:$PINECONE_CAIRO_SYSROOT/usr/share/pkgconfig"
    export CFLAGS="${CFLAGS:-} -isystem $PINECONE_CAIRO_SYSROOT/usr/include"
    export LDFLAGS="${LDFLAGS:-} -L$PINECONE_CAIRO_SYSROOT/usr/lib -Wl,-rpath-link,$PINECONE_CAIRO_SYSROOT/usr/lib"
    STOCK_LIBDIR="$PINECONE_CAIRO_SYSROOT/usr/lib"
fi
tar -xf "$ARCHIVE" -C "$WORK"
patch --batch --forward -p1 -d "$WORK/cairo-$VERSION" < "$ROOT/scripts/patches/cairo-pinecone-cpu-access.patch"
meson setup "$WORK/build" "$WORK/cairo-$VERSION" \
    --prefix=/usr --libdir=lib --buildtype=release --wrap-mode=nofallback \
    -Dtests=disabled -Dgtk_doc=false -Dglib=enabled -Dpng=enabled \
    -Dfontconfig=enabled -Dfreetype=enabled -Dxlib=enabled -Dxcb=enabled -Dzlib=enabled
meson compile -C "$WORK/build" -j "${PINECONE_CAIRO_JOBS:-4}"
DESTDIR="$WORK/stage" meson install --no-rebuild -C "$WORK/build"
bash "$ROOT/scripts/run-cairo-access-regressions.sh" "$WORK/stage/usr/lib" "$STOCK_LIBDIR"
for library in cairo cairo-gobject cairo-script-interpreter; do
    file="lib$library.so.2.11804.4"
    readelf -h "$WORK/stage/usr/lib/$file" | grep -q 'Machine:.*AArch64'
    if readelf -d "$WORK/stage/usr/lib/$file" | grep -Eq 'RPATH|RUNPATH'; then
        echo "Unexpected runtime search path in $file" >&2
        exit 1
    fi
    install -m 0755 "$WORK/stage/usr/lib/$file" "$OUTPUT/$file"
    ln -sfn "$file" "$OUTPUT/lib$library.so.2"
done
readelf -Ws "$OUTPUT/libcairo.so.2" | grep 'pinecone_pixman_get_data_escaping' > /dev/null
python3 "$ROOT/scripts/cairo-runtime-manifest.py" create "$OUTPUT"
python3 "$ROOT/scripts/cairo-runtime-manifest.py" verify "$OUTPUT"
sha256sum "$OUTPUT"/*.so.2.11804.4
echo "Built and tested Cairo runtime overlay: $OUTPUT"
