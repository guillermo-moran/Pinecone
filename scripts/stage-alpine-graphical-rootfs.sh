#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:?usage: stage-alpine-graphical-rootfs.sh ROOTFS_DIR}"
CACHE_DIR="${ARM64VIZ_GRAPHICAL_PACKAGE_CACHE:-${ROOT_DIR}/artifacts/alpine-packages/edge-aarch64}"
BASE_URL="https://dl-cdn.alpinelinux.org/alpine/edge"
repository_url() {
  case "$1" in
    browser) printf '%s' 'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' ;;
    main|community) printf '%s/%s' "$BASE_URL" "$1" ;;
    *) echo "Unknown package repository: $1" >&2; return 1 ;;
  esac
}
PROFILE="${ARM64VIZ_GRAPHICAL_PROFILE:-phoc}"
TARGETS=(cage evtest foot seatd font-dejavu apk-tools alpine-keys busybox busybox-binsh)
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
      firefox
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
overlay_index="${selected_file}.overlay-index.$$"
overlay_list="${selected_file}.overlays.$$"
visited_file="${selected_file}.visited.$$"
download_staging=""
index_staging=""
cleanup() {
  rm -f "${selected_file_staging}" "${pinned_index}" "${overlay_index}" "${overlay_list}" "${visited_file}"
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

apk_metadata() {
  local archive="$1" repository="$2" package="$3" version="$4"
  bsdtar -xOf "${archive}" .PKGINFO | awk -F ' = ' \
    -v repository="${repository}" -v package="${package}" -v version="${version}" '
    $1 == "pkgname" { name=$2 }
    $1 == "pkgver" { ver=$2 }
    $1 == "arch" { arch=$2 }
    $1 == "provides" { provides=provides " " $2 }
    $1 == "depend" { dependencies=dependencies " " $2 }
    END {
      if (name != package || ver != version ||
          (arch != "aarch64" && (arch != "noarch" || repository == "overlay"))) exit 1
      print "R:" repository "\nP:" name "\nV:" ver "\np:" provides "\nD:" dependencies "\n"
    }'
}

register_overlay() {
  local package="$1" version="$2" directory="$3"
  local archive="${ROOT_DIR}/artifacts/alpine-packages/${directory}/aarch64/${package}-${version}.apk"
  if [[ ! -s "${archive}" ]]; then
    echo "Missing Pinecone overlay: ${archive}; build this package first." >&2
    exit 1
  fi
  apk_metadata "${archive}" overlay "${package}" "${version}" >> "${overlay_index}"
  printf '%s|%s|%s\n' "${archive}" "${package}" "${version}" >> "${overlay_list}"
}

is_overlaid() {
  awk -F '|' -v package="$1" '$2 == package { found=1 } END { exit !found }' "${overlay_list}"
}

# Resolve the effective runtime packages before extracting anything. The cached
# distribution selection remains pinned; overlays replace its providers, not its pins.
: > "${overlay_index}"
: > "${overlay_list}"
: > "${visited_file}"
if [[ "${PINECONE_USE_PATCHED_WLROOTS:-1}" == "1" ]]; then
  register_overlay wlroots0.20 0.20.2-r6 pinecone-wlroots
fi
if [[ "${PROFILE}" != cage && "${PINECONE_USE_PATCHED_PHOC:-1}" == "1" ]]; then
  register_overlay phoc 0.57.0-r7 pinecone-phoc
fi
if [[ "${PROFILE}" == phosh && "${PINECONE_USE_PATCHED_PHOSH:-1}" == "1" ]]; then
  register_overlay phosh 0.57.0-r8 pinecone-phosh
fi
if [[ "${PROFILE}" == phosh && "${PINECONE_USE_PATCHED_SETTINGS:-1}" == "1" ]]; then
  register_overlay gnome-control-center 50.4-r2 pinecone-gnome-control-center
fi
if [[ "${PINECONE_USE_PATCHED_GLIB:-1}" == "1" ]]; then
  register_overlay glib 2.88.3-r1 pinecone-glib
fi
if [[ "${PINECONE_USE_PATCHED_MUSL:-1}" == "1" ]]; then
  register_overlay musl 1.2.6-r8 pinecone-musl
fi

repositories=(main community)
[[ "$PROFILE" != phosh ]] || repositories+=(browser)
for repository in "${repositories[@]}"; do
  archive="${CACHE_DIR}/${repository}-APKINDEX.tar.gz"
  index="${CACHE_DIR}/${repository}-APKINDEX"
  if [[ "${ARM64VIZ_REUSE_GRAPHICAL_PACKAGE_INDEX:-1}" == "1" && -s "${index}" ]]; then
    continue
  fi
  download_archive "${archive}" \
    "$(repository_url "$repository")/aarch64/APKINDEX.tar.gz"
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
  # Audit retained consumers too: an overlay may remove a previously provided ABI.
  while IFS='|' read -r repository package version; do
    if is_overlaid "${package}"; then
      continue
    fi
    archive="${CACHE_DIR}/${package}-${version}.apk"
    if [[ -s "${archive}" ]]; then
      apk_metadata "${archive}" "${repository}" "${package}" "${version}" >> "${pinned_index}"
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
  local order=(overlay pinned main community)
  # Keep the existing codec ABI: stable Firefox/FFmpeg use libx265.so.215.
  # All other dependencies continue resolving against the pinned/edge platform.
  if [[ "$PROFILE" == phosh ]]; then
    case "$dependency" in
      firefox|ffmpeg-libavcodec|so:libvpx.so.11) order=(overlay pinned browser main community) ;;
    esac
  fi
  for repository in "${order[@]}"; do
    if [[ "${repository}" == "overlay" ]]; then
      index="${overlay_index}"
    elif [[ "${repository}" == "pinned" ]]; then
      index="${pinned_index}"
    else
      index="${CACHE_DIR}/${repository}-APKINDEX"
    fi
    match="$({ awk -v requested="${dependency}" -v repository="${repository}" \
      -v overlays="${overlay_list}" -v pins="${pinned_index}" '
      BEGIN {
        RS="\n"
        while ((getline record < overlays) > 0) { split(record, fields, "|"); replaced[fields[2]]=1 }
        close(overlays)
        RS=""; FS="\n"
        while ((getline record < pins) > 0) {
          n=split(record, fields, "\n"); name=""; ver=""
          for (i=1; i<=n; i++) {
            if (fields[i] ~ /^P:/) name=substr(fields[i],3)
            if (fields[i] ~ /^V:/) ver=substr(fields[i],3)
          }
          known[name]=ver
        }
        close(pins)
      }
      {
        package=""; version=""; provides=""; source=repository
        for (line = 1; line <= NF; line++) {
          if ($line ~ /^P:/) package=substr($line, 3)
          else if ($line ~ /^V:/) version=substr($line, 3)
          else if ($line ~ /^p:/) provides=substr($line, 3)
          else if ($line ~ /^R:/) source=substr($line, 3)
        }
        if (repository != "overlay" && package in replaced) next
        if (repository != "overlay" && repository != "pinned" && known[package] == version) next
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
  local index="${3:-${CACHE_DIR}/${repository}-APKINDEX}"
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
  ' "${index}"
}

# Always walk the requested targets, including when reusing a pinned selection.
{
  queue=("${TARGETS[@]}")
  # Include overlays not named as targets, plus pinned packages no longer reached
  # from the target graph. They will still be staged and must remain ABI-compatible.
  while IFS='|' read -r archive package version; do
    queue+=("${package}")
  done < "${overlay_list}"
  while IFS='|' read -r repository package version; do
    queue+=("${package}")
  done < "${selected_file_staging}"
  cursor=0

  while (( cursor < ${#queue[@]} )); do
    dependency="${queue[cursor]}"
    cursor=$((cursor + 1))
    required_by="${dependency#*|}"
    dependency="${dependency%%|*}"
    dependency="${dependency%%[<>=~]*}"
    [[ -z "${dependency}" || "${dependency}" == "!"* || "${dependency}" == /* ]] && continue
    if ! record="$(lookup_package "${dependency}")"; then
      echo "Unable to resolve Alpine runtime dependency: ${dependency} (required by ${required_by}); preserve pins and rebuild the incompatible overlay or supply a compatible provider." >&2
      exit 1
    fi
    IFS='|' read -r repository package version <<<"${record}"
    if grep -Fqx "${record}" "${visited_file}"; then
      continue
    fi
    printf '%s\n' "${record}" >> "${visited_file}"
    if [[ "${repository}" == overlay ]]; then
      dependency_line="$(package_dependencies "${package}" overlay "${overlay_index}")"
    else
      existing="$(awk -F '|' -v package="${package}" '$2 == package { print; exit }' "${selected_file_staging}")"
      if [[ -n "${existing}" ]]; then
        if [[ "${existing}" != "${record}" ]]; then
          echo "Dependency ${dependency} requires ${record}, conflicting with pinned ${existing}; resolve this package explicitly." >&2
          exit 1
        fi
      else
        printf '%s|%s|%s\n' "${repository}" "${package}" "${version}" >> "${selected_file_staging}"
      fi

      archive="${CACHE_DIR}/${package}-${version}.apk"
      if [[ ! -s "${archive}" ]]; then
        download_archive "${archive}" "$(repository_url "$repository")/aarch64/${package}-${version}.apk"
      fi
      metadata="$(apk_metadata "${archive}" "${repository}" "${package}" "${version}")"
      # The selected APK must actually provide the requested ABI, even if an index
      # advertised it. Newly downloaded package dependencies come from that APK too.
      if ! awk -v requested="${dependency}" '
        /^P:/ { if (substr($0,3) == requested) found=1 }
        /^p:/ { n=split(substr($0,3), values, " "); for (i=1;i<=n;i++) {
          sub(/[=<>~].*$/, "", values[i]); if (values[i] == requested) found=1
        } }
        END { exit !found }
      ' <<<"${metadata}"; then
        echo "APK ${package}-${version} does not provide ${dependency} required by ${required_by}; refusing an ABI conflict." >&2
        exit 1
      fi
      dependency_line="$(sed -n 's/^D://p' <<<"${metadata}")"
      # Keep index dependencies for new selections as a conservative supplement.
      if [[ -z "${existing}" ]]; then
        dependency_line+=" $(package_dependencies "${package}" "${repository}")"
        printf '%s\n\n' "${metadata}" >> "${pinned_index}"
      fi
    fi
    if [[ -n "${dependency_line}" ]]; then
      read -r -a dependencies <<<"${dependency_line}"
      for dependency in ${dependencies[@]+"${dependencies[@]}"}; do
        queue+=("${dependency}|${repository} ${package}-${version}")
      done
    fi
  done
  if [[ "${ARM64VIZ_GRAPHICAL_VALIDATE_ONLY:-0}" == "1" ]]; then
    echo "Validated Alpine ${PROFILE} runtime closure and custom APKs; no packages extracted or selection changed."
    exit 0
  fi
}

while IFS='|' read -r repository package version; do
  if is_overlaid "${package}"; then
    continue
  fi
  archive="${CACHE_DIR}/${package}-${version}.apk"
  if [[ ! -s "${archive}" ]]; then
    download_archive "${archive}" "$(repository_url "$repository")/aarch64/${package}-${version}.apk"
  fi
  bsdtar -xf "${archive}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL --exclude .pre-install --exclude .post-install
done < "${selected_file_staging}"

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
  install -m 0755 "${ROOT_DIR}/scripts/rootfs/pinecone-launch-firefox" \
    "${DESTINATION}/usr/local/bin/pinecone-launch-firefox"
  install -m 0644 "${ROOT_DIR}/scripts/rootfs/pinecone-firefox-user.js" \
    "${DESTINATION}/usr/share/pinecone/browser/firefox-user.js"
  install -m 0644 "${ROOT_DIR}/scripts/rootfs/pinecone-firefox.desktop" \
    "${DESTINATION}/usr/share/applications/firefox.desktop"
  test -x "${DESTINATION}/usr/bin/firefox"
  test -x "${DESTINATION}/usr/libexec/dbus-daemon-launch-helper"
  test -s "${DESTINATION}/etc/ssl/certs/ca-certificates.crt"
fi

while IFS='|' read -r archive package version; do
  bsdtar -xf "${archive}" -C "${DESTINATION}" \
    --exclude .SIGN.RSA.* --exclude .PKGINFO --exclude .INSTALL \
    --exclude .pre-install --exclude .post-install --exclude .trigger
  echo "Staged Pinecone ${package} ${version}"
done < "${overlay_list}"

# Metadata is necessary but not sufficient: verify the overlay's SONAMEs also
# exist in the extracted root. Resolve absolute symlinks inside that root, never
# against host libraries. Native linker/symbol checks belong in the cache chroot.
python3 - "${DESTINATION}" "${overlay_index}" <<'PY'
from collections import deque
import os
from pathlib import Path, PurePosixPath
import re
import sys

root = Path(sys.argv[1]).resolve()

def guest_file(path):
    pending = deque(PurePosixPath(path).parts)
    current = root
    hops = 0
    while pending:
        part = pending.popleft()
        if part in ("/", "."):
            continue
        if part == "..":
            current = current.parent if current != root else root
            continue
        candidate = current / part
        if candidate.is_symlink():
            hops += 1
            if hops > 40:
                return None
            target = os.readlink(candidate)
            if target.startswith("/"):
                current = root
            pending.extendleft(reversed(PurePosixPath(target).parts))
        else:
            current = candidate
    return current if current.is_file() else None

paths = ["/lib", "/usr/local/lib", "/usr/lib"]
config = guest_file("/etc/ld-musl-aarch64.path")
if config:
    paths = [p for p in re.split(r"[:\n]", config.read_text()) if p.startswith("/")]
missing = []
for record in Path(sys.argv[2]).read_text().split("\n\n"):
    fields = dict(line.split(":", 1) for line in record.splitlines() if ":" in line)
    for dependency in fields.get("D", "").split():
        if not dependency.startswith("so:"):
            continue
        soname = re.split(r"[=<>~]", dependency[3:], maxsplit=1)[0]
        if not any(guest_file(f"{directory}/{soname}") for directory in paths):
            missing.append(f"{fields.get('P')}-{fields.get('V')}: {dependency}")
if missing:
    sys.exit("Missing staged overlay runtime libraries:\n  " + "\n  ".join(missing))
PY

mv "${selected_file_staging}" "${selected_file}"
# The image builder uses these exact archives to let APK generate its own
# installed database, including file ownership, scripts, and triggers.
if [[ -n "${PINECONE_APK_MANIFEST_OUT:-}" ]]; then
  : > "${PINECONE_APK_MANIFEST_OUT}"
  while IFS='|' read -r repository package version; do
    is_overlaid "${package}" && continue
    printf '%s|%s|%s\n' "${CACHE_DIR}/${package}-${version}.apk" "${package}" "${version}" \
      >> "${PINECONE_APK_MANIFEST_OUT}"
  done < "${selected_file}"
  cat "${overlay_list}" >> "${PINECONE_APK_MANIFEST_OUT}"
fi
package_count="$(wc -l < "${selected_file}" | tr -d ' ')"
printf 'Staged %s Alpine %s graphical packages into %s\n' \
  "${package_count}" "${PROFILE}" "${DESTINATION}"
