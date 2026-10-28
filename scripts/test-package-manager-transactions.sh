#!/usr/bin/env bash
# Runs only against a disposable copy of the built image in an aarch64 Linux VM.
set -euo pipefail
[[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 && "$(id -u)" == 0 ]] || {
  echo 'Run as root in an aarch64 Linux build VM.' >&2
  exit 1
}
IMAGE="${1:?usage: test-package-manager-transactions.sh ROOTFS_IMAGE}"
WORK="$(mktemp -d /tmp/pinecone-package-smoke.XXXXXX)"
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then umount "$WORK/root"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
cp "$IMAGE" "$WORK/rootfs.ext4"
mkdir "$WORK/root"
mount -o loop "$WORK/rootfs.ext4" "$WORK/root"
mounted=1
mkdir -p "$WORK/root/dev"
mknod -m 0666 "$WORK/root/dev/null" c 1 3
run_apk() {
  chroot "$WORK/root" /sbin/apk --no-progress --timeout 30 --wait 5 \
    --repositories-file /dev/null \
    -X https://dl-cdn.alpinelinux.org/alpine/edge/main \
    -X https://dl-cdn.alpinelinux.org/alpine/edge/community "$@"
}
cp /etc/resolv.conf "$WORK/root/etc/resolv.conf"
test -s "$WORK/root/usr/share/pinecone/platform-packages.txt"
chroot "$WORK/root" /usr/local/bin/pinecone-packages --self-test
sha256sum "$WORK/root/usr/bin/phoc" "$WORK/root/lib/ld-musl-aarch64.so.1" > "$WORK/core-before"
run_apk update
run_apk add --simulate -- tree htop
run_apk add --no-interactive -- tree htop
chroot "$WORK/root" /usr/bin/tree --version
chroot "$WORK/root" /usr/bin/htop --version
grep -qx tree "$WORK/root/etc/apk/world"
grep -qx htop "$WORK/root/etc/apk/world"
sync
umount "$WORK/root"
mounted=0
mount -o loop "$WORK/rootfs.ext4" "$WORK/root"
mounted=1
chroot "$WORK/root" /usr/bin/tree --version
chroot "$WORK/root" /usr/bin/htop --version
run_apk add --simulate --upgrade -- htop
run_apk del --simulate -- tree htop
run_apk del --no-interactive -- tree htop
test ! -e "$WORK/root/usr/bin/tree"
test ! -e "$WORK/root/usr/bin/htop"
candidate="$(run_apk query --from repositories --format json --fields name,version --match name -- musl |
  python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["version"])')"
if grep -Fqx "musl=$candidate" "$WORK/root/usr/share/pinecone/platform-packages.txt"; then
  echo 'The pin test requires a repository libc different from the patched runtime.' >&2
  exit 1
fi
if run_apk add --simulate "musl=$candidate" > "$WORK/protected.log" 2>&1; then
  echo 'ERROR: the platform version constraint was not enforced' >&2
  exit 1
fi
grep -q '.pinecone-platform' "$WORK/protected.log"
echo "Refused replacement with repository musl=$candidate because the platform pins the patched version."
sha256sum -c "$WORK/core-before"
echo 'Package update/install/remount/remove and platform protection smoke passed.'
