#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:?usage: stage-alpine-graphical-rootfs.sh ROOTFS_DIR}"
CACHE_DIR="${ROOT_DIR}/artifacts/alpine-packages/edge-aarch64"
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

for repository in main community; do
  archive="${CACHE_DIR}/${repository}-APKINDEX.tar.gz"
  index="${CACHE_DIR}/${repository}-APKINDEX"
  if [[ "${ARM64VIZ_REUSE_GRAPHICAL_PACKAGE_INDEX:-0}" == "1" &&
        -s "${archive}" && -s "${index}" ]]; then
    continue
  fi
  archive_staging="${archive}.staging.$$"
  curl -fL --retry 3 -o "${archive_staging}" \
    "${BASE_URL}/${repository}/aarch64/APKINDEX.tar.gz"
  mv "${archive_staging}" "${archive}"
  bsdtar -xOf "${archive}" APKINDEX > "${index}"
done

lookup_package() {
  local dependency="$1"
  local repository index match
  for repository in main community; do
    index="${CACHE_DIR}/${repository}-APKINDEX"
    match="$({ awk -v requested="${dependency}" -v repository="${repository}" '
      BEGIN { RS=""; FS="\n" }
      {
        package=""; version=""; provides=""
        for (line = 1; line <= NF; line++) {
          if ($line ~ /^P:/) package=substr($line, 3)
          else if ($line ~ /^V:/) version=substr($line, 3)
          else if ($line ~ /^p:/) provides=substr($line, 3)
        }
        if (package == requested) {
          print repository "|" package "|" version
          exit
        }
        count=split(provides, values, " ")
        for (i=1; i<=count; i++) {
          provided=values[i]
          sub(/[=<>~].*$/, "", provided)
          if (provided == requested) {
            print repository "|" package "|" version
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

selected_file="${CACHE_DIR}/selected-graphical-packages-${PROFILE}.txt"
if [[ "${ARM64VIZ_REUSE_GRAPHICAL_PACKAGE_SELECTION:-0}" != "1" || ! -s "${selected_file}" ]]; then
  selected_file_staging="${selected_file}.staging.$$"
  rm -f "${selected_file_staging}"
  : > "${selected_file_staging}"
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
    grep -q "^[^|]*|${package}|" "${selected_file_staging}" && continue
    printf '%s|%s|%s\n' "${repository}" "${package}" "${version}" >> "${selected_file_staging}"

    dependency_line="$(package_dependencies "${package}" "${repository}")"
    if [[ -n "${dependency_line}" ]]; then
      read -r -a dependencies <<<"${dependency_line}"
      queue+=("${dependencies[@]}")
    fi
  done
  mv "${selected_file_staging}" "${selected_file}"
fi

while IFS='|' read -r repository package version; do
  archive="${CACHE_DIR}/${package}-${version}.apk"
  if [[ ! -s "${archive}" ]]; then
    curl -fL --retry 3 -o "${archive}" "${BASE_URL}/${repository}/aarch64/${package}-${version}.apk"
  fi
  bsdtar -xf "${archive}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL --exclude .pre-install --exclude .post-install
done < "${selected_file}"

PINECONE_WLROOTS="${ROOT_DIR}/artifacts/alpine-packages/pinecone-wlroots/aarch64/wlroots0.20-0.20.2-r3.apk"
if [[ "${PINECONE_USE_PATCHED_WLROOTS:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_WLROOTS}" ]]; then
    echo "Missing Pinecone wlroots package: ${PINECONE_WLROOTS}" >&2
    echo "Run scripts/build-pinecone-wlroots.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_WLROOTS}" .PKGINFO)"
  grep -qx 'pkgname = wlroots0.20' <<<"${package_info}"
  grep -qx 'pkgver = 0.20.2-r3' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_WLROOTS}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL
  echo "Staged Pinecone wlroots 0.20.2-r3"
fi

PINECONE_PHOC="${ROOT_DIR}/artifacts/alpine-packages/pinecone-phoc/aarch64/phoc-0.57.0-r1.apk"
if [[ "${PROFILE}" != "cage" && "${PINECONE_USE_PATCHED_PHOC:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_PHOC}" ]]; then
    echo "Missing Pinecone Phoc package: ${PINECONE_PHOC}" >&2
    echo "Run scripts/build-pinecone-phoc.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_PHOC}" .PKGINFO)"
  grep -qx 'pkgname = phoc' <<<"${package_info}"
  grep -qx 'pkgver = 0.57.0-r1' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_PHOC}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL
  echo "Staged Pinecone Phoc 0.57.0-r1"
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

PINECONE_SETTINGS="${ROOT_DIR}/artifacts/alpine-packages/pinecone-gnome-control-center/aarch64/gnome-control-center-50.4-r1.apk"
if [[ "${PROFILE}" == "phosh" && "${PINECONE_USE_PATCHED_SETTINGS:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_SETTINGS}" ]]; then
    echo "Missing Pinecone GNOME Settings package: ${PINECONE_SETTINGS}" >&2
    echo "Run scripts/build-pinecone-gnome-control-center.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_SETTINGS}" .PKGINFO)"
  grep -qx 'pkgname = gnome-control-center' <<<"${package_info}"
  grep -qx 'pkgver = 50.4-r1' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_SETTINGS}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL
  echo "Staged Pinecone GNOME Settings 50.4-r1"
fi

PINECONE_MUSL="${ROOT_DIR}/artifacts/alpine-packages/pinecone-musl/aarch64/musl-1.2.6-r6.apk"
if [[ "${PINECONE_USE_PATCHED_MUSL:-1}" == "1" ]]; then
  if [[ ! -f "${PINECONE_MUSL}" ]]; then
    echo "Missing Pinecone musl package: ${PINECONE_MUSL}" >&2
    echo "Run scripts/build-pinecone-musl.sh first." >&2
    exit 1
  fi
  package_info="$(bsdtar -xOf "${PINECONE_MUSL}" .PKGINFO)"
  grep -qx 'pkgname = musl' <<<"${package_info}"
  grep -qx 'pkgver = 1.2.6-r6' <<<"${package_info}"
  grep -qx 'arch = aarch64' <<<"${package_info}"
  bsdtar -xf "${PINECONE_MUSL}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL
  echo "Staged Pinecone musl 1.2.6-r6"
fi

package_count="$(wc -l < "${selected_file}" | tr -d ' ')"
printf 'Staged %s Alpine %s graphical packages into %s\n' \
  "${package_count}" "${PROFILE}" "${DESTINATION}"
