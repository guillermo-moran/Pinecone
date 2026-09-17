#!/usr/bin/env bash
set -euo pipefail

# Native Alpine only. No package manager, installation, or shared source writes.
ARCHIVE="${1:?usage: build-isolated.sh musl-1.2.6.tar.gz alpine-patch-dir new-work-dir}"
ALPINE_PATCHES="${2:?missing Alpine patch directory}"
WORK="${3:?missing new work directory}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATS="${PINECONE_MUSL_STARTUP_STATS_BUILD:-0}"
case "$STATS" in 0|1) ;; *) echo "stats build must be 0 or 1" >&2; exit 2 ;; esac
[[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 ]] || {
  echo "Requires native Linux/aarch64" >&2; exit 2;
}
ARCHIVE="$(realpath "$ARCHIVE")"
ALPINE_PATCHES="$(cd "$ALPINE_PATCHES" && pwd)"
mkdir "$WORK"
WORK="$(cd "$WORK" && pwd)"
mkdir "$WORK/source" "$WORK/build"
tar -xf "$ARCHIVE" --strip-components=1 -C "$WORK/source"
cd "$WORK/source"
for name in handle-aux-at_base.patch \
  0001-add-stub-for-pthread_mutexattr_setprioceiling.patch \
  fix-loongarch64-zero-len-extcontext.patch \
  CVE-2026-6042.patch CVE-2026-40200.patch; do
  patch --fuzz=0 -p1 < "$ALPINE_PATCHES/$name"
done
patch --fuzz=0 -p1 < "$ROOT/patches/musl-pinecone-startup-symbol-cache.patch"
cd "$WORK/build"
flags="-O2"
[[ "$STATS" == 0 ]] || flags="$flags -DPINECONE_MUSL_STARTUP_STATS=1"
../source/configure --disable-static --enable-debug --prefix=/usr \
  CFLAGS="$flags" LDFLAGS="-Wl,-soname,libc.musl-aarch64.so.1" > configure.log
make -j"${JOBS:-2}" > build.log 2>&1
cp lib/libc.so "$WORK/ld-musl-aarch64.so.1"
printf 'Isolated loader: %s/ld-musl-aarch64.so.1\n' "$WORK"
