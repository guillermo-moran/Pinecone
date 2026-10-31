#!/bin/sh
# Build-only Linux check. All guest writes are confined to a scratch /tmp bind.
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
  mount --make-rprivate /
  loop=$(losetup -f)
  losetup -r "$loop" "$image"
  mount -t ext4 -o ro,noload "$loop" "$root"
  mount --bind "$out/scratch" "$root/tmp"
  cat /proc/mounts >"$out/mounts.log"
  awk '/^P:(glib|pango|gtk4\.0|gtksourceview5|libspelling)$/ {p=$0; getline; print p, $0}' \
    "$root/lib/apk/db/installed" >"$out/packages.log"
  guest() {
    chroot "$root" /bin/busybox env -i PATH=/usr/bin:/bin HOME=/tmp/home \
      XDG_CACHE_HOME=/tmp/cache LD_LIBRARY_PATH=/tmp/abi/lib \
      PC_TEXT_EXPECT_GTK=4.22.4 "$@"
  }
  preload=/tmp/abi/lib/libpinecone-text-commit.so
  if [ -f "$out/scratch/abi/lib/libpinecone-text-wait.so" ]; then
    preload=/tmp/abi/lib/libpinecone-text-wait.so:$preload
  fi
  guest /lib/ld-musl-aarch64.so.1 --list /tmp/abi/test-buffer >"$out/loader.log" 2>&1
  guest LD_PRELOAD="$preload" /tmp/abi/test-load 2.88.3 1.57.1 4.22.4 >"$out/load.log" 2>&1
  for enabled in 0 1; do
    guest PINECONE_TEXT_INSERTION_TRACE="$enabled" \
      LD_PRELOAD="$preload" \
      /tmp/abi/test-buffer >"$out/buffer-$enabled.log" 2>&1
    guest PINECONE_TEXT_INSERTION_TRACE="$enabled" \
      LD_PRELOAD="$preload" \
      /tmp/abi/test-commit >"$out/commit-$enabled.log" 2>&1
  done
  guest PINECONE_TEXT_INSERTION_TRACE=1 PC_TEXT_TEST_STANDALONE=1 \
    LD_PRELOAD="$preload" \
    /tmp/abi/test-buffer >"$out/standalone.log" 2>&1
  exit 0
fi
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo 'usage: sh test-guest-abi.sh READONLY-IMAGE EXISTING-V2-WORK NEW-OUTPUT [WAIT-LIBRARY-DIRECTORY]' >&2
  exit 2
fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=$(realpath "$1")
work=$(realpath "$2")
mkdir "$3"
out=$(CDPATH= cd -- "$3" && pwd)
mkdir -p "$out/root" "$out/scratch/abi/lib" "$out/scratch/home" "$out/scratch/cache"
# The existing callback fixture has this absolute DT_NEEDED path.
fixture=/tmp/pinecone-insertion-sourceview-v2/private-gtk-commit-test
mkdir -p "$out/scratch/${fixture#/tmp/}"
cp "$work/private-gtk-commit-test/libspelling-1.so.fixture" "$out/scratch/${fixture#/tmp/}/"
cp "$work/private-gtk-buffer-test2/test-buffer" "$out/scratch/abi/"
cp "$work/private-gtk-commit-test/test-commit" "$out/scratch/abi/"
cp "$work/build/gtksourceview/libgtksourceview-5.so.0.0.0" "$out/scratch/abi/lib/libgtksourceview-5.so.0"
cp "$work/runtime/libpinecone-text-trace.so" "$work/runtime/libpinecone-text-commit.so" \
  "$work/private-gtk/libgtk-4.so.1" "$out/scratch/abi/lib/"
if [ "$#" -eq 4 ]; then
  cp "$4/libpinecone-text-wait.so" "$out/scratch/abi/lib/"
fi
sha256sum "$out"/scratch/abi/lib/* >"$out/libraries.sha256"
cc -std=c11 -O2 -Wall -Wextra -Werror -Wshadow "$src/test-load.c" -ldl \
  -o "$out/scratch/abi/test-load"
sudo -n unshare -m --propagation private sh "$src/test-guest-abi.sh" --mounted "$image" "$out"
for log in buffer-1 commit-1 standalone; do
  python3 "$src/analyze.py" "$out/$log.log" >"$out/$log.json"
  if [ "$#" -eq 4 ]; then
    python3 "$src/analyze-wait.py" "$out/$log.log" >"$out/$log-wait.json"
  fi
done
test "$(grep -c 'name=spelling.commit.' "$out/commit-1.log")" = 5
grep -q 'parent=0 .*name=gtk_source_buffer_real_insert_text ' "$out/standalone.log"
printf 'Guest dependency ABI/regressions passed: %s\n' "$out"
