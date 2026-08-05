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
      polkit
      weston-clients
      portfolio
      gnome-calculator
      gnome-calendar
      gnome-clocks
      gnome-text-editor
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
  if [[ ! -s "${archive}" ]]; then
    curl -fL --retry 3 -o "${archive}" "${BASE_URL}/${repository}/aarch64/APKINDEX.tar.gz"
  fi
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
  : > "${selected_file}"
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
    grep -q "^[^|]*|${package}|" "${selected_file}" && continue
    printf '%s|%s|%s\n' "${repository}" "${package}" "${version}" >> "${selected_file}"

    dependency_line="$(package_dependencies "${package}" "${repository}")"
    if [[ -n "${dependency_line}" ]]; then
      read -r -a dependencies <<<"${dependency_line}"
      queue+=("${dependencies[@]}")
    fi
  done
fi

while IFS='|' read -r repository package version; do
  archive="${CACHE_DIR}/${package}-${version}.apk"
  if [[ ! -s "${archive}" ]]; then
    curl -fL --retry 3 -o "${archive}" "${BASE_URL}/${repository}/aarch64/${package}-${version}.apk"
  fi
  bsdtar -xf "${archive}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL --exclude .pre-install --exclude .post-install
done < "${selected_file}"

package_count="$(wc -l < "${selected_file}" | tr -d ' ')"
printf 'Staged %s Alpine %s graphical packages into %s\n' \
  "${package_count}" "${PROFILE}" "${DESTINATION}"
