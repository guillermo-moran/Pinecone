#!/usr/bin/env bash
# Native build only: use preinstalled dependencies/signing configuration.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# != 2 ]]; then
  echo "usage: build-pinecone-text-editor.sh SOURCE_TAR_GZ NEW_OUTPUT_DIR" >&2
  exit 2
fi
[[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 ]] || {
  echo "Run natively in the aarch64 builder or its private build chroot." >&2
  exit 1
}
for tool in abuild abuild-meson meson ninja pkg-config itstool msgfmt readelf \
    desktop-file-validate update-desktop-database appstreamcli; do
  command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done
pkg-config --exists gio-2.0 gtk4 gtksourceview-5 libadwaita-1 libspelling-1 editorconfig
archive="$(realpath "$1")"
mkdir "$2"
out="$(cd "$2" && pwd)"
mkdir -p "$out/build" "$out/distfiles" "$out/apks"
cp "$ROOT/scripts/alpine/gnome-text-editor/APKBUILD" "$out/build/"
cp "$ROOT/scripts/text-insertion/editor-path-literal.patch" "$out/build/"
cp "$archive" "$out/distfiles/gnome-text-editor-50.1.tar.gz"
apk info -v | sort > "$out/build-packages.txt"
cp "$out/build/APKBUILD" "$out/build/editor-path-literal.patch" "$out/"
export SRCDEST="$out/distfiles" REPODEST="$out/packages"
cd "$out/build"
# -d forbids automatic dependency installation; -K preserves source/test logs.
# Running as root is supported for an explicitly selected private chroot.
abuild -F -d -K 2>&1 | tee "$out/build.log"
find "$out/packages" -name '*.apk' -exec cp {} "$out/apks/" \;
package="$out/apks/gnome-text-editor-50.1-r1.apk"
test -s "$package"
tar -xOf "$package" .PKGINFO > "$out/PKGINFO"
grep -qx 'pkgname = gnome-text-editor' "$out/PKGINFO"
grep -qx 'pkgver = 50.1-r1' "$out/PKGINFO"
grep -qx 'arch = aarch64' "$out/PKGINFO"
tar -xOf "$package" usr/bin/gnome-text-editor > "$out/gnome-text-editor"
chmod 0755 "$out/gnome-text-editor"
readelf -d "$out/gnome-text-editor" > "$out/readelf-dynamic.txt"
readelf --dyn-syms --wide "$out/gnome-text-editor" > "$out/readelf-symbols.txt"
if grep -Eq 'RPATH|RUNPATH|libpinecone-text' "$out/readelf-dynamic.txt" ||
   grep -Eq 'UND.* (wordexp|wordfree)(@|$)' "$out/readelf-symbols.txt"; then
  echo "unexpected build path, trace dependency, or wordexp reference" >&2
  exit 1
fi
cp src/gnome-text-editor-50.1/output/meson-logs/testlog.txt "$out/testlog.txt"
cd "$out"
sha256sum gnome-text-editor apks/*.apk > SHA256SUMS
printf 'Candidate built (guest ABI validation still required): %s\n' "$out"
