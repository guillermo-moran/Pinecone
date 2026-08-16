#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${PIXMAN_VERSION:-0.46.4}"
ARCHIVE="${ROOT_DIR}/artifacts/pixman-source/pixman-${VERSION}.tar.xz"
SOURCE_URL="https://www.cairographics.org/releases/pixman-${VERSION}.tar.xz"
EXPECTED_SHA512="83b133e7969ba34f883f4e08dcc5d388c4397f43ce836c191c05945fe77c16ff501d531600780c12678a0d08105828a6bdeff2156b63f9c1a84087bc7f40ae9f"
PATCH="${ROOT_DIR}/scripts/patches/pixman-pinecone-2d.patch"
OUTPUT="${1:-${ROOT_DIR}/artifacts/linux-shell/out/libpixman-1.so.0.46.4}"
CLANG="${CLANG:-/opt/homebrew/opt/llvm/bin/clang}"
LLVM_AR="${LLVM_AR:-/opt/homebrew/opt/llvm/bin/llvm-ar}"
LLVM_STRIP="${LLVM_STRIP:-/opt/homebrew/opt/llvm/bin/llvm-strip}"

MESON="${MESON:-}"
NINJA="${NINJA:-}"
if [[ -z "${MESON}" ]]; then
  MESON="$(command -v meson 2>/dev/null || true)"
fi
if [[ -z "${NINJA}" ]]; then
  NINJA="$(command -v ninja 2>/dev/null || true)"
fi
TOOL_CANDIDATES=(
  "${TMPDIR:-/tmp}/pinecone-build-tools/bin"
  "/tmp/pinecone-build-tools/bin"
)
for tools in "${TOOL_CANDIDATES[@]}"; do
  [[ -n "${MESON}" ]] || [[ ! -x "${tools}/meson" ]] || MESON="${tools}/meson"
  [[ -n "${NINJA}" ]] || [[ ! -x "${tools}/ninja" ]] || NINJA="${tools}/ninja"
done
[[ -x "${MESON}" && -x "${NINJA}" ]] || {
  echo 'meson and ninja are required to build Pinecone Pixman' >&2
  exit 1
}

MESON_COMMAND=("${MESON}")
if ! "${MESON_COMMAND[@]}" --version >/dev/null 2>&1; then
  MESON_ROOT="$(cd "$(dirname "${MESON}")/.." && pwd)"
  MESON_PYTHON=""
  for candidate in /opt/homebrew/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
    [[ -n "${candidate}" && -x "${candidate}" ]] || continue
    if PYTHONPATH="${MESON_ROOT}" "${candidate}" -c \
      'from mesonbuild.mesonmain import main' >/dev/null 2>&1; then
      MESON_PYTHON="${candidate}"
      break
    fi
  done
  [[ -n "${MESON_PYTHON}" ]] || {
    echo "meson launcher is unusable and no compatible Python can import ${MESON_ROOT}/mesonbuild" >&2
    exit 1
  }
  MESON_COMMAND=(env "PYTHONPATH=${MESON_ROOT}" "${MESON_PYTHON}" -m mesonbuild.mesonmain)
fi

mkdir -p "$(dirname "${ARCHIVE}")" "$(dirname "${OUTPUT}")"
if [[ ! -f "${ARCHIVE}" ]]; then
  curl --fail --location --output "${ARCHIVE}" "${SOURCE_URL}"
fi
ACTUAL_SHA512="$(shasum -a 512 "${ARCHIVE}" | awk '{print $1}')"
[[ "${ACTUAL_SHA512}" == "${EXPECTED_SHA512}" ]] || {
  echo "Pixman ${VERSION} source checksum mismatch" >&2
  exit 1
}

CACHE_DIR="${ROOT_DIR}/artifacts/alpine-packages/edge-aarch64"
MUSL_DEV="$(find "${CACHE_DIR}" -maxdepth 1 -name 'musl-dev-*.apk' -print -quit)"
MUSL_RUNTIME="$(find "${CACHE_DIR}" -maxdepth 1 -name 'musl-[0-9]*.apk' -print -quit)"
[[ -n "${MUSL_DEV}" && -n "${MUSL_RUNTIME}" ]] || {
  echo 'missing cached Alpine aarch64 musl or musl-dev package' >&2
  exit 1
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pinecone-pixman-source.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
SYSROOT="${WORK_DIR}/sysroot"
SOURCE_DIR="${WORK_DIR}/pixman-${VERSION}"
BUILD_DIR="${WORK_DIR}/build"
mkdir -p "${SYSROOT}"
bsdtar -xf "${MUSL_DEV}" -C "${SYSROOT}" \
  --exclude '.SIGN.RSA.*' --exclude .PKGINFO
bsdtar -xf "${MUSL_RUNTIME}" -C "${SYSROOT}" \
  --exclude '.SIGN.RSA.*' --exclude .PKGINFO
tar -C "${WORK_DIR}" -xf "${ARCHIVE}"
patch --batch --forward -d "${SOURCE_DIR}" -p1 < "${PATCH}"

CROSS_FILE="${WORK_DIR}/aarch64-linux-musl.ini"
cat > "${CROSS_FILE}" <<EOF
[binaries]
c = '${CLANG}'
ar = '${LLVM_AR}'
strip = '${LLVM_STRIP}'
pkg-config = '/opt/homebrew/bin/pkg-config'

[built-in options]
c_args = ['--target=aarch64-linux-musl', '--sysroot=${SYSROOT}', '-O3']
c_link_args = ['--target=aarch64-linux-musl', '--sysroot=${SYSROOT}', '-fuse-ld=lld', '-nostdlib', '-Wl,--no-as-needed,-lc']

[properties]
needs_exe_wrapper = true
sys_root = '${SYSROOT}'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

PATH="$(dirname "${NINJA}"):${PATH}" "${MESON_COMMAND[@]}" setup \
  "${BUILD_DIR}" "${SOURCE_DIR}" \
  --cross-file "${CROSS_FILE}" \
  --buildtype release \
  --default-library shared \
  -Db_lundef=false \
  --prefix /usr \
  --libdir lib \
  -Dtests=disabled \
  -Ddemos=disabled \
  -Dgtk=disabled \
  -Dlibpng=disabled \
  -Dmmx=disabled \
  -Dsse2=disabled \
  -Dssse3=disabled \
  -Dvmx=disabled \
  -Darm-simd=disabled \
  -Dneon=disabled \
  -Da64-neon=enabled \
  -Dmips-dspr2=disabled \
  -Drvv=disabled
PATH="$(dirname "${NINJA}"):${PATH}" "${MESON_COMMAND[@]}" compile -C "${BUILD_DIR}"
install -m 0755 \
  "${BUILD_DIR}/pixman/libpixman-1.so.0.46.4" \
  "${OUTPUT}"

echo "Built Pinecone Pixman library: ${OUTPUT}"
