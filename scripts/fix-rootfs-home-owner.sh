#!/usr/bin/env bash
# Correct host UID leakage from an unprivileged mke2fs -d build, offline only.
set -euo pipefail
image="${1:?usage: fix-rootfs-home-owner.sh IMAGE}"
debugfs="${DEBUGFS:-$(command -v debugfs || true)}"
if [[ -z "$debugfs" && -x /opt/homebrew/opt/e2fsprogs/sbin/debugfs ]]; then
  debugfs=/opt/homebrew/opt/e2fsprogs/sbin/debugfs
fi
[[ -f "$image" && -x "$debugfs" ]] || {
  echo 'an offline ext4 image and e2fsprogs debugfs are required' >&2
  exit 1
}
"$debugfs" -w -R 'set_inode_field /root uid 0' "$image"
"$debugfs" -w -R 'set_inode_field /root gid 0' "$image"
"$debugfs" -w -R 'set_inode_field /root mode 040700' "$image"
# debugfs can return success even when an individual command fails.
metadata="$("$debugfs" -R 'stat /root' "$image")"
grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' <<< "$metadata"
grep -Eq 'Type: directory[[:space:]]+Mode:[[:space:]]+0700' <<< "$metadata"
