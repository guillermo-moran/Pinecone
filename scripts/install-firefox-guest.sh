#!/usr/bin/env bash
# Linux build-VM worker. Operate only on an offline, backed-up image copy.
set -euo pipefail
image="${1:?usage: install-firefox-guest.sh IMAGE ROOTFS_ASSETS PIXMAN_BRIDGE}"
assets="${2:?missing rootfs assets directory}"
bridge="${3:?missing rebuilt libpinecone-pixman.so}"
[[ -s "$bridge" ]]
[[ "$(id -u)" == 0 && -f "$image" ]]
work="$(mktemp -d /tmp/pinecone-firefox.XXXXXX)"
mounted=0
cleanup() {
  if (( mounted )); then umount "$work"; fi
  rmdir "$work"
}
trap cleanup EXIT
status=0
e2fsck -pf "$image" || status=$?
(( status <= 1 ))
size="$(stat -c %s "$image")"
if (( size < 1610612736 )); then
  truncate -s 1536M "$image"
  resize2fs "$image"
fi
mount -o loop,nodev,nosuid "$image" "$work"
mounted=1
chown 0:0 "$work/root"
chmod 0700 "$work/root"
test -s "$work/usr/share/pinecone/platform-packages.txt"
cp "$work/usr/share/pinecone/platform-packages.txt" "$work/tmp/pinecone-platform-before-firefox.txt"
# The installed .pinecone-platform constraints prohibit upgrading the custom
# graphics stack or other pinned libraries to satisfy the browser dependency set.
apk --root "$work" --keys-dir /etc/apk/keys --repositories-file /dev/null \
  --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
  --repository https://dl-cdn.alpinelinux.org/alpine/edge/community \
  --repository '@browser https://dl-cdn.alpinelinux.org/alpine/v3.24/community' \
  --no-scripts --update-cache add firefox@browser ffmpeg-libavcodec@browser
cmp "$work/usr/share/pinecone/platform-packages.txt" "$work/tmp/pinecone-platform-before-firefox.txt"
rm "$work/tmp/pinecone-platform-before-firefox.txt"
browser_repo='@browser https://dl-cdn.alpinelinux.org/alpine/v3.24/community'
grep -qxF "$browser_repo" "$work/etc/apk/repositories" || \
  printf '%s\n' "$browser_repo" >> "$work/etc/apk/repositories"
install -D -m 0755 "$assets/pinecone-launch-firefox" "$work/usr/local/bin/pinecone-launch-firefox"
install -D -m 0644 "$assets/pinecone-firefox-user.js" "$work/usr/share/pinecone/browser/firefox-user.js"
install -D -m 0644 "$assets/pinecone-firefox.desktop" "$work/usr/share/applications/firefox.desktop"
install -D -m 0755 "$bridge" "$work/usr/lib/libpinecone-pixman.so"
manifest="$work/usr/share/pinecone/phosh-apps.list"
grep -qxF firefox.desktop "$manifest" || printf '%s\n' firefox.desktop >> "$manifest"
schema="$work/usr/share/glib-2.0/schemas/99-pinecone.gschema.override"
# Change the shipped default, not an existing user's dconf preferences.
sed -i "s/favorites=\['netsurf.desktop'/favorites=['firefox.desktop'/" "$schema"
if ! grep '^force-adaptive=' "$schema" | grep -q "'firefox.desktop'"; then
  sed -i "/^force-adaptive=/s/\]$/,'firefox.desktop']/" "$schema"
fi
chroot "$work" /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas
chroot "$work" /usr/bin/update-desktop-database /usr/share/applications
apk --root "$work" --repositories-file /dev/null --repository "$browser_repo" --no-network fix --simulate
sync
umount "$work"
mounted=0
e2fsck -fn "$image"
