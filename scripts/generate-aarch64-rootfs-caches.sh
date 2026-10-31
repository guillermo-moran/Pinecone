#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${1:?usage: generate-aarch64-rootfs-caches.sh ROOTFS_DIR}"
INSTANCE="${PINECONE_CACHE_LIMA_INSTANCE:-pinecone-wlroots}"

[[ -x "${ROOTFS}/usr/bin/fc-cache" ]] || {
  echo "missing aarch64 fc-cache in ${ROOTFS}" >&2
  exit 1
}
[[ -x "${ROOTFS}/usr/bin/gdk-pixbuf-query-loaders" ]] || {
  echo "missing aarch64 gdk-pixbuf-query-loaders in ${ROOTFS}" >&2
  exit 1
}
uses_gtk3() {
  [[ -e "${1}/usr/lib/libgtk-3.so.0" || -L "${1}/usr/lib/libgtk-3.so.0" ||
     -e "${1}/usr/bin/gtk-query-immodules-3.0" ]]
}
if uses_gtk3 "${ROOTFS}" && [[ ! -x "${ROOTFS}/usr/bin/gtk-query-immodules-3.0" ]]; then
  echo "missing aarch64 gtk-query-immodules-3.0 in ${ROOTFS}" >&2
  exit 1
fi
mkdir -p "${ROOTFS}/var/cache/fontconfig"
chmod 0755 "${ROOTFS}/var/cache/fontconfig"

validate_graphical_linker() {
  local rootfs="$1" executable
  for executable in /usr/bin/phoc /usr/libexec/phosh /usr/bin/squeekboard \
      /usr/bin/netsurf-gtk3 /usr/local/bin/pinecone-packages /sbin/apk; do
    [[ -x "${rootfs}${executable}" ]] || continue
    # Resolve the binaries that will ship, without starting their UI or services.
    chroot "${rootfs}" /lib/ld-musl-aarch64.so.1 --list "${executable}" >/dev/null
  done
  if [[ -x "${rootfs}/usr/local/bin/pinecone-packages" ]]; then
    chroot "${rootfs}" /usr/local/bin/pinecone-packages --self-test
    chroot "${rootfs}" /sbin/apk --no-network fix --simulate
  fi
}

generate_gio_module_caches() {
  local rootfs="$1" directory
  # Match glib.trigger: unpacking APKs does not run these registrations.
  # Query the shipped modules with the shipped tool, never the host's GIO.
  for directory in /usr/lib/gio/modules /usr/lib/gtk-4.0; do
    [[ -d "${rootfs}${directory}" ]] || continue
    [[ -x "${rootfs}/usr/bin/gio-querymodules" ]] || {
      echo "missing aarch64 gio-querymodules in ${rootfs}" >&2
      return 1
    }
    chroot "${rootfs}" /usr/bin/gio-querymodules "${directory}"
  done
}

generate_icon_caches() {
  local rootfs="$1" theme tool
  for theme in "${rootfs}"/usr/share/icons/*; do
    [[ -f "${theme}/index.theme" ]] || continue
    tool=/usr/bin/gtk-update-icon-cache
    if [[ ! -x "${rootfs}${tool}" ]]; then
      tool=/usr/bin/gtk4-update-icon-cache
    fi
    [[ -x "${rootfs}${tool}" ]] || {
      echo "missing aarch64 gtk-update-icon-cache (or gtk4-update-icon-cache) in ${rootfs}" >&2
      return 1
    }
    # Both GTK versions consume this index. Keep image bytes in their original
    # files, and regenerate after all theme/application icons have been staged.
    chroot "${rootfs}" "${tool}" --force --index-only "${theme#"${rootfs}"}"
    [[ -s "${theme}/icon-theme.cache" ]] || {
      echo "missing generated icon-theme.cache in ${theme}" >&2
      return 1
    }
    chroot "${rootfs}" "${tool}" --validate "${theme#"${rootfs}"}"
  done
}

generate_in_chroot() {
  local rootfs="$1"
  validate_graphical_linker "${rootfs}"
  generate_gio_module_caches "${rootfs}"
  chroot "${rootfs}" /usr/bin/fc-cache --system-only --really-force
  mkdir -p "${rootfs}/usr/lib/gdk-pixbuf-2.0/2.10.0"
  chroot "${rootfs}" /usr/bin/gdk-pixbuf-query-loaders > \
    "${rootfs}/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
  generate_icon_caches "${rootfs}"
  # APK extraction does not run GTK's trigger. Without this registry GTK
  # cannot discover the Wayland text-input module used by Squeekboard.
  if uses_gtk3 "${rootfs}"; then
    mkdir -p "${rootfs}/usr/lib/gtk-3.0/3.0.0"
    chroot "${rootfs}" /usr/bin/gtk-query-immodules-3.0 > \
      "${rootfs}/usr/lib/gtk-3.0/3.0.0/immodules.cache"
  fi
  validate_input_modules "${rootfs}"
}

validate_input_modules() {
  uses_gtk3 "$1" || return 0
  grep -q '^"/usr/lib/gtk-3.0/3.0.0/immodules/im-wayland.so"' \
    "${1}/usr/lib/gtk-3.0/3.0.0/immodules.cache" &&
  grep -q '^"wayland" ' "${1}/usr/lib/gtk-3.0/3.0.0/immodules.cache" || {
    echo "GTK Wayland input module is missing from the generated registry" >&2
    return 1
  }
}

if [[ "$(uname -s)" == "Linux" ]]; then
  if [[ "$(id -u)" == "0" ]]; then
    generate_in_chroot "${ROOTFS}"
  else
    sudo bash -e -c "$(declare -f uses_gtk3 generate_in_chroot generate_gio_module_caches generate_icon_caches validate_input_modules validate_graphical_linker); generate_in_chroot \"\$1\"" -- "${ROOTFS}"
  fi
  exit 0
fi

command -v limactl >/dev/null 2>&1 || {
  echo "Lima is required to generate aarch64 runtime caches on macOS" >&2
  exit 1
}
limactl start "${INSTANCE}" >/dev/null

lima_shell() {
  limactl shell --shell /bin/sh "${INSTANCE}" "$@"
}

# Existing Lima instances can expose the workspace read-only. Stage one tar
# archive on Lima's writable disk, run the exact binaries that will ship in
# the image, and copy back only the generated caches.
HOST_ROOTFS_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/pinecone-rootfs-cache.tar.XXXXXX")"
HOST_CACHE_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/pinecone-generated-cache.tar.XXXXXX")"
GUEST_WORK="$(lima_shell mktemp -d /tmp/pinecone-rootfs-cache.XXXXXX)"
GUEST_ROOT="${GUEST_WORK}/root"
GUEST_ROOTFS_ARCHIVE="${GUEST_WORK}/rootfs.tar"
GUEST_CACHE_ARCHIVE="${GUEST_WORK}/generated-cache.tar"
cleanup() {
  rm -f "${HOST_ROOTFS_ARCHIVE}" "${HOST_CACHE_ARCHIVE}"
  lima_shell sudo rm -rf "${GUEST_WORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

COPYFILE_DISABLE=1 bsdtar --no-xattrs -cf "${HOST_ROOTFS_ARCHIVE}" \
  -C "${ROOTFS}" .
limactl copy "${HOST_ROOTFS_ARCHIVE}" "${INSTANCE}:${GUEST_ROOTFS_ARCHIVE}"
lima_shell sudo mkdir -p "${GUEST_ROOT}"
lima_shell sudo tar -xf "${GUEST_ROOTFS_ARCHIVE}" -C "${GUEST_ROOT}"
lima_shell sudo bash -e -c \
  "$(declare -f validate_graphical_linker); validate_graphical_linker \"\$1\"" -- "${GUEST_ROOT}"
lima_shell sudo bash -e -c \
  "$(declare -f generate_gio_module_caches); generate_gio_module_caches \"\$1\"" -- "${GUEST_ROOT}"
lima_shell sudo chroot "${GUEST_ROOT}" \
  /usr/bin/fc-cache --system-only --really-force
lima_shell sudo mkdir -p \
  "${GUEST_ROOT}/usr/lib/gdk-pixbuf-2.0/2.10.0"
lima_shell sudo sh -c \
  "chroot '$GUEST_ROOT' /usr/bin/gdk-pixbuf-query-loaders > '$GUEST_ROOT/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache'"
CACHE_PATHS=(var/cache/fontconfig usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache)
lima_shell sudo bash -e -c \
  "$(declare -f generate_icon_caches); generate_icon_caches \"\$1\"" -- "${GUEST_ROOT}"
for theme in "${ROOTFS}"/usr/share/icons/*; do
  [[ -f "${theme}/index.theme" ]] || continue
  CACHE_PATHS+=("${theme#"${ROOTFS}/"}/icon-theme.cache")
done
for directory in usr/lib/gio/modules usr/lib/gtk-4.0; do
  [[ -d "${ROOTFS}/${directory}" ]] || continue
  if lima_shell sudo test -f "${GUEST_ROOT}/${directory}/giomodule.cache"; then
    CACHE_PATHS+=("${directory}/giomodule.cache")
  else
    # No queryable modules is valid; gio-querymodules removes a stale cache.
    rm -f "${ROOTFS}/${directory}/giomodule.cache"
  fi
done
if uses_gtk3 "${ROOTFS}"; then
  lima_shell sudo mkdir -p "${GUEST_ROOT}/usr/lib/gtk-3.0/3.0.0"
  lima_shell sudo sh -c \
    "chroot '$GUEST_ROOT' /usr/bin/gtk-query-immodules-3.0 > '$GUEST_ROOT/usr/lib/gtk-3.0/3.0.0/immodules.cache'"
  CACHE_PATHS+=(usr/lib/gtk-3.0/3.0.0/immodules.cache)
fi
lima_shell sudo tar -cf "${GUEST_CACHE_ARCHIVE}" \
  -C "${GUEST_ROOT}" "${CACHE_PATHS[@]}"
limactl copy "${INSTANCE}:${GUEST_CACHE_ARCHIVE}" "${HOST_CACHE_ARCHIVE}"
bsdtar -xf "${HOST_CACHE_ARCHIVE}" -C "${ROOTFS}"
for theme in "${ROOTFS}"/usr/share/icons/*; do
  [[ -f "${theme}/index.theme" ]] || continue
  # Extraction can advance the parent mtime past the archived cache. GTK
  # rejects that cache even though its contents match this unchanged theme.
  touch -r "${theme}" "${theme}/icon-theme.cache"
done

find "${ROOTFS}/var/cache/fontconfig" -type f -name '*cache-*' -print -quit | grep -q .
test -s "${ROOTFS}/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
validate_input_modules "${ROOTFS}"
