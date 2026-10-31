#!/bin/sh
# The image stays read-only; only a private scratch /tmp is writable.
set -eu
if [ "${1:-}" = --mounted ]; then
  image=$2
  out=$3
  root=$out/root
  loop=
  cleanup() {
    umount "$root/tmp" 2>/dev/null || :
    umount "$root" 2>/dev/null || :
    if [ -n "$loop" ]; then losetup -d "$loop"; fi
  }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  loop=$(losetup -f)
  losetup -r "$loop" "$image"
  mount -t ext4 -o ro,noload "$loop" "$root"
  mount --bind "$out/scratch" "$root/tmp"
  cat /proc/mounts > "$out/mounts.log"
  awk '/^P:(glib|gtk4\.0|gtksourceview5|libadwaita|libspelling|libeditorconfig)$/ {
    p=$0; getline; print p, $0
  }' "$root/lib/apk/db/installed" > "$out/guest-packages.txt"
  guest() {
    chroot "$root" /bin/busybox env -i PATH=/usr/bin:/bin HOME=/tmp/home \
      XDG_CACHE_HOME=/tmp/cache \
      LD_LIBRARY_PATH=/lib:/usr/lib:/usr/lib/pulseaudio:/usr/lib/samba "$@"
  }
  guest /lib/ld-musl-aarch64.so.1 --list /tmp/gnome-text-editor > "$out/loader.log" 2>&1
  guest /tmp/gnome-text-editor --version > "$out/version.log" 2>&1
  grep -q 'Text Editor 50.1' "$out/version.log"
  grep -Eq 'GTK: 4\.22\.4 ' "$out/version.log"
  grep -Eq 'GtkSourceView: 5\.20\.0 ' "$out/version.log"
  if grep -Eq 'Error relocating|Error loading|libpinecone-text' "$out/loader.log"; then
    cat "$out/loader.log" >&2
    exit 1
  fi
  exit 0
fi
if [ "$#" != 3 ]; then
  echo 'usage: test-text-editor-guest-abi.sh READONLY_IMAGE EXECUTABLE NEW_OUTPUT_DIR' >&2
  exit 2
fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=$(realpath "$1")
executable=$(realpath "$2")
mkdir "$3"
out=$(CDPATH= cd -- "$3" && pwd)
mkdir -p "$out/root" "$out/scratch/home" "$out/scratch/cache"
cp "$executable" "$out/scratch/gnome-text-editor"
chmod 0755 "$out/scratch/gnome-text-editor"
sha256sum "$out/scratch/gnome-text-editor" > "$out/executable.sha256"
readelf -d "$executable" > "$out/readelf-dynamic.txt"
sudo -n unshare -m --propagation private sh "$src/test-text-editor-guest-abi.sh" \
  --mounted "$image" "$out"
cat "$out/version.log"
printf 'Exact guest ABI check passed: %s\n' "$out"
