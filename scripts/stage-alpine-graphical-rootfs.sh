#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:?usage: stage-alpine-graphical-rootfs.sh ROOTFS_DIR}"
CACHE_DIR="${ARM64VIZ_GRAPHICAL_PACKAGE_CACHE:-${ROOT_DIR}/artifacts/alpine-packages/edge-aarch64}"
BASE_URL="https://dl-cdn.alpinelinux.org/alpine/edge"
PROFILE="${ARM64VIZ_GRAPHICAL_PROFILE:-phoc}"
TARGETS=(cage evtest foot seatd font-dejavu)
case "${PROFILE}" in
  cage)
    ;;
  phoc)
    TARGETS+=(dbus phoc weston-clients)
    ;;
  phosh)
    TARGETS+=(
      at-spi2-core
      dbus
      dbus-daemon-launch-helper
      elogind
      phoc
      phosh
      polkit-elogind
      util-linux-login
      weston-clients
      portfolio
      gnome-calculator
      gnome-calendar
      gnome-clocks
      gnome-text-editor
      networkmanager
      netsurf
      ca-certificates
      ca-certificates-bundle
    )
    ;;
  *)
    echo "Unknown graphical profile: ${PROFILE} (expected cage, phoc, or phosh)" >&2
    exit 2
    ;;
esac
if [[ -n "${ARM64VIZ_EXTRA_GRAPHICAL_PACKAGES:-}" ]]; then
  read -r -a extra_targets <<<"${ARM64VIZ_EXTRA_GRAPHICAL_PACKAGES}"
  TARGETS+=("${extra_targets[@]}")
fi

mkdir -p "${CACHE_DIR}" "${DESTINATION}"

selected_file="${CACHE_DIR}/selected-graphical-packages-${PROFILE}.txt"
selected_file_staging="${selected_file}.staging.$$"
pinned_index="${selected_file}.pinned-index.$$"
download_staging=""
index_staging=""
cleanup() {
  rm -f "${selected_file_staging}" "${pinned_index}"
  [[ -z "${download_staging}" ]] || rm -f "${download_staging}"
  [[ -z "${index_staging}" ]] || rm -f "${index_staging}"
}
trap cleanup EXIT

download_archive() {
  local destination="$1" url="$2"
  download_staging="${destination}.staging.$$"
  curl -fL --retry 3 -o "${download_staging}" "${url}"
  bsdtar -tf "${download_staging}" >/dev/null
  mv "${download_staging}" "${destination}"
  download_staging=""
}

for repository in main community; do
  archive="${CACHE_DIR}/${repository}-APKINDEX.tar.gz"
  index="${CACHE_DIR}/${repository}-APKINDEX"
  if [[ "${ARM64VIZ_REUSE_GRAPHICAL_PACKAGE_INDEX:-1}" == "1" && -s "${index}" ]]; then
    continue
  fi
  download_archive "${archive}" \
    "${BASE_URL}/${repository}/aarch64/APKINDEX.tar.gz"
  index_staging="${index}.staging.$$"
  bsdtar -xOf "${archive}" APKINDEX > "${index_staging}"
  mv "${index_staging}" "${index}"
  index_staging=""
done

: > "${selected_file_staging}"
: > "${pinned_index}"
if [[ "${ARM64VIZ_REUSE_GRAPHICAL_PACKAGE_SELECTION:-1}" == "1" && -s "${selected_file}" ]]; then
  cp "${selected_file}" "${selected_file_staging}"
  # Use the actual pinned APK's provides, not a newer index entry's SONAMEs.
  # Only newly selected packages need their dependency closure expanded.
  while IFS='|' read -r repository package version; do
    archive="${CACHE_DIR}/${package}-${version}.apk"
    if [[ -s "${archive}" ]]; then
      package_info="$(bsdtar -xOf "${archive}" .PKGINFO)"
      printf '%s\n' "${package_info}" | awk -F ' = ' \
        -v repository="${repository}" -v package="${package}" -v version="${version}" '
        $1 == "pkgname" { name=$2 }
        $1 == "pkgver" { ver=$2 }
        $1 == "arch" { arch=$2 }
        $1 == "provides" { provides=provides " " $2 }
        END {
          if (name != package || ver != version || (arch != "aarch64" && arch != "noarch")) exit 1
          print "R:" repository "\nP:" name "\nV:" ver "\np:" provides "\n"
        }' >> "${pinned_index}"
    else
      # A missing archive is safe only if the index still describes this pin.
      match="$(awk -v package="${package}" -v version="${version}" '
        BEGIN { RS=""; FS="\n" }
        { p=""; v=""; for (i=1; i<=NF; i++) {
            if ($i ~ /^P:/) p=substr($i,3)
            if ($i ~ /^V:/) v=substr($i,3)
          }
          if (p == package && v == version) { print; exit }
        }' "${CACHE_DIR}/${repository}-APKINDEX")"
      if [[ -z "${match}" ]]; then
        echo "Missing metadata for pinned ${package}-${version}; restore its cached APK (do not refresh all dependencies)." >&2
        exit 1
      fi
      printf 'R:%s\n%s\n\n' "${repository}" "${match}" >> "${pinned_index}"
    fi
  done < "${selected_file}"
fi

lookup_package() {
  local dependency="$1"
  local repository index match
  for repository in pinned main community; do
    if [[ "${repository}" == "pinned" ]]; then
      index="${pinned_index}"
    else
      index="${CACHE_DIR}/${repository}-APKINDEX"
    fi
    match="$({ awk -v requested="${dependency}" -v repository="${repository}" '
      BEGIN { RS=""; FS="\n" }
      {
        package=""; version=""; provides=""; source=repository
        for (line = 1; line <= NF; line++) {
          if ($line ~ /^P:/) package=substr($line, 3)
          else if ($line ~ /^V:/) version=substr($line, 3)
          else if ($line ~ /^p:/) provides=substr($line, 3)
          else if ($line ~ /^R:/) source=substr($line, 3)
        }
        if (package == requested) {
          print source "|" package "|" version
          exit
        }
        count=split(provides, values, " ")
        for (i=1; i<=count; i++) {
          provided=values[i]
          sub(/[=<>~].*$/, "", provided)
          if (provided == requested) {
            print source "|" package "|" version
            exit
          }
        }
      }
    ' "${index}"; } || true)"
    if [[ -n "${match}" ]]; then
      printf '%s\n' "${match}"
      return 0
    fi
  done
  return 1
}

package_dependencies() {
  local package="$1"
  local repository="$2"
  awk -v requested="${package}" '
    BEGIN { RS=""; FS="\n" }
    {
      package=""; dependencies=""
      for (line = 1; line <= NF; line++) {
        if ($line ~ /^P:/) package=substr($line, 3)
        else if ($line ~ /^D:/) dependencies=substr($line, 3)
      }
      if (package == requested) {
        print dependencies
        exit
      }
    }
  ' "${CACHE_DIR}/${repository}-APKINDEX"
}

# Always walk the requested targets, including when reusing a pinned selection.
{
  queue=("${TARGETS[@]}")
  cursor=0

  while (( cursor < ${#queue[@]} )); do
    dependency="${queue[cursor]}"
    cursor=$((cursor + 1))
    dependency="${dependency%%[<>=~]*}"
    [[ -z "${dependency}" || "${dependency}" == "!"* || "${dependency}" == /* ]] && continue
    if ! record="$(lookup_package "${dependency}")"; then
      echo "Unable to resolve Alpine runtime dependency: ${dependency}" >&2
      exit 1
    fi
    IFS='|' read -r repository package version <<<"${record}"
    existing="$(awk -F '|' -v package="${package}" '$2 == package { print; exit }' "${selected_file_staging}")"
    if [[ -n "${existing}" ]]; then
      if [[ "${existing}" != "${record}" ]]; then
        echo "Dependency ${dependency} requires ${record}, conflicting with pinned ${existing}; resolve this package explicitly." >&2
        exit 1
      fi
      continue
    fi
    printf '%s|%s|%s\n' "${repository}" "${package}" "${version}" >> "${selected_file_staging}"

    dependency_line="$(package_dependencies "${package}" "${repository}")"
    if [[ -n "${dependency_line}" ]]; then
      read -r -a dependencies <<<"${dependency_line}"
      queue+=("${dependencies[@]}")
    fi
  done
  mv "${selected_file_staging}" "${selected_file}"
}

while IFS='|' read -r repository package version; do
  archive="${CACHE_DIR}/${package}-${version}.apk"
  if [[ ! -s "${archive}" ]]; then
    download_archive "${archive}" "${BASE_URL}/${repository}/aarch64/${package}-${version}.apk"
  fi
  bsdtar -xf "${archive}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL --exclude .pre-install --exclude .post-install
done < "${selected_file}"

if [[ "${PROFILE}" == "phosh" ]]; then
  install -d "${DESTINATION}/usr/local/bin" "${DESTINATION}/usr/share/pinecone/browser" \
    "${DESTINATION}/usr/share/applications"
  install -m 0755 "${ROOT_DIR}/scripts/rootfs/pinecone-launch-browser" \
    "${DESTINATION}/usr/local/bin/pinecone-launch-browser"
  install -m 0644 "${ROOT_DIR}/scripts/rootfs/pinecone-browser.Choices" \
    "${DESTINATION}/usr/share/pinecone/browser/Choices"
  # Keep the distribution desktop ID and icon; replace its direct Exec path.
  install -m 0644 "${ROOT_DIR}/scripts/rootfs/pinecone-browser.desktop" \
    "${DESTINATION}/usr/share/applications/netsurf.desktop"
  test -x "${DESTINATION}/usr/bin/netsurf-gtk3"
  test -x "${DESTINATION}/usr/libexec/dbus-daemon-launch-helper"
  test -s "${DESTINATION}/etc/ssl/certs/ca-certificates.crt"
fi

PINECONE_WLROOTS="${ROOT_DIR}/artifacts/alpine-packages/pinecone-wlroots/aarch64/wlroots0.20-0.20.2-r4.apk"
if [[ "${PINECONE_USE_PATCHED_WLROOTS:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_WLROOTS}" ]]; then
    echo "Missing Pinecone wlroots package: ${PINECONE_WLROOTS}" >&2
    echo "Run scripts/build-pinecone-wlroots.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_WLROOTS}" .PKGINFO)"
  grep -qx 'pkgname = wlroots0.20' <<<"${package_info}"
  grep -qx 'pkgver = 0.20.2-r4' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_WLROOTS}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL
  echo "Staged Pinecone wlroots 0.20.2-r4"
fi

PINECONE_PHOC="${ROOT_DIR}/artifacts/alpine-packages/pinecone-phoc/aarch64/phoc-0.57.0-r5.apk"
if [[ "${PROFILE}" != "cage" && "${PINECONE_USE_PATCHED_PHOC:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_PHOC}" ]]; then
    echo "Missing Pinecone Phoc package: ${PINECONE_PHOC}" >&2
    echo "Run scripts/build-pinecone-phoc.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_PHOC}" .PKGINFO)"
  grep -qx 'pkgname = phoc' <<<"${package_info}"
  grep -qx 'pkgver = 0.57.0-r5' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_PHOC}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL
  echo "Staged Pinecone Phoc 0.57.0-r5"
fi

PINECONE_PHOSH="${ROOT_DIR}/artifacts/alpine-packages/pinecone-phosh/aarch64/phosh-0.57.0-r3.apk"
if [[ "${PROFILE}" == "phosh" && "${PINECONE_USE_PATCHED_PHOSH:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_PHOSH}" ]]; then
    echo "Missing Pinecone Phosh package: ${PINECONE_PHOSH}" >&2
    echo "Run scripts/build-pinecone-phosh.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_PHOSH}" .PKGINFO)"
  grep -qx 'pkgname = phosh' <<<"${package_info}"
  grep -qx 'pkgver = 0.57.0-r3' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_PHOSH}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL --exclude .trigger
  echo "Staged Pinecone Phosh 0.57.0-r3"
fi

PINECONE_SETTINGS="${ROOT_DIR}/artifacts/alpine-packages/pinecone-gnome-control-center/aarch64/gnome-control-center-50.4-r2.apk"
if [[ "${PROFILE}" == "phosh" && "${PINECONE_USE_PATCHED_SETTINGS:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_SETTINGS}" ]]; then
    echo "Missing Pinecone GNOME Settings package: ${PINECONE_SETTINGS}" >&2
    echo "Run scripts/build-pinecone-gnome-control-center.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_SETTINGS}" .PKGINFO)"
  grep -qx 'pkgname = gnome-control-center' <<<"${package_info}"
  grep -qx 'pkgver = 50.4-r2' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_SETTINGS}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL
  echo "Staged Pinecone GNOME Settings 50.4-r2"
fi

PINECONE_GLIB="${ROOT_DIR}/artifacts/alpine-packages/pinecone-glib/aarch64/glib-2.88.3-r1.apk"
if [[ "${PINECONE_USE_PATCHED_GLIB:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_GLIB}" ]]; then
    echo "Missing Pinecone GLib package: ${PINECONE_GLIB}" >&2
    echo "Run scripts/build-pinecone-glib.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_GLIB}" .PKGINFO)"
  grep -qx 'pkgname = glib' <<<"${package_info}"
  grep -qx 'pkgver = 2.88.3-r1' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_GLIB}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL
  echo "Staged Pinecone GLib 2.88.3-r1"
fi

PINECONE_MUSL="${ROOT_DIR}/artifacts/alpine-packages/pinecone-musl/aarch64/musl-1.2.6-r8.apk"
if [[ "${PINECONE_USE_PATCHED_MUSL:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_MUSL}" ]]; then
    echo "Missing Pinecone musl package: ${PINECONE_MUSL}" >&2
    echo "Run scripts/build-pinecone-musl.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_MUSL}" .PKGINFO)"
  grep -qx 'pkgname = musl' <<<"${package_info}"
  grep -qx 'pkgver = 1.2.6-r8' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_MUSL}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL
  echo "Staged Pinecone musl 1.2.6-r8"
fi

package_count="$(wc -l < "${selected_file}" | tr -d ' ')"
printf 'Staged %s Alpine %s graphical packages into %s\n' \
  "${package_count}" "${PROFILE}" "${DESTINATION}"
