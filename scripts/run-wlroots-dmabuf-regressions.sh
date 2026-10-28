#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:-${PHOC_SOURCE_ARCHIVE:-}}"
if [[ $# -gt 1 || ! -f "$ARCHIVE" ]]; then
  echo "Usage: $0 /path/to/phoc-0.57.0.tar.xz (or set PHOC_SOURCE_ARCHIVE)" >&2
  exit 1
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wlroots-dmabuf-regression.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
tar -xf "$ARCHIVE" -C "$WORK" phoc-0.57.0/subprojects/wlroots-0.20.x
WLR="$WORK/phoc-0.57.0/subprojects/wlroots-0.20.x"
patch --fuzz=0 -s -d "$WLR" -p1 < "$ROOT/scripts/patches/wlroots-pinecone-0.20.2.patch"
patch --fuzz=0 -s -d "$WLR" -p1 < "$ROOT/scripts/patches/wlroots-pinecone-dmabuf.patch"
patch --fuzz=0 -s -d "$WLR" -p1 < "$ROOT/scripts/patches/wlroots-pinecone-ownership.patch"

# Use the exact implementation from the applied patch, replacing only platform
# includes with the regression's DRM model. No parallel copy of importer logic.
sed '/^#include /d' "$WLR/render/pixman/dmabuf.c" > "$WORK/dmabuf-under-test.inc"
"${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
  ${WLROOTS_DMABUF_TEST_CFLAGS:-} -I"$WORK" \
  "$ROOT/scripts/wlroots-dmabuf-regression.c" -o "$WORK/regression"
"$WORK/regression"

# Linux builders exercise actual Wayland epoll/timer dispatch and compile against
# the patched upstream headers, not a duplicate model of the readiness logic.
if [[ "${WLROOTS_DMABUF_TEST_WAYLAND:-auto}" != 0 && "$(uname -s)" == Linux ]] && \
    command -v pkg-config >/dev/null && pkg-config --exists wayland-server pixman-1 libdrm; then
  sed '/^#include /d' "$WLR/render/pixman/dmabuf_wait.c" > "$WORK/dmabuf-wait-under-test.inc"
  sed -n '/^uint32_t wlr_surface_lock_pending(/,/^struct wlr_surface \*wlr_surface_get_root_surface(/p' \
    "$WLR/types/wlr_compositor.c" | sed '$d' > "$WORK/surface-unlock-under-test.inc"
  sed -n '/^static void buffer_consider_destroy(/,/^bool wlr_buffer_get_dmabuf(/p' \
    "$WLR/types/buffer/buffer.c" | sed '$d' > "$WORK/buffer-lifetime-under-test.inc"
  "${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
    ${WLROOTS_DMABUF_TEST_CFLAGS:-} -D_GNU_SOURCE -DWLR_USE_UNSTABLE -DWLR_PRIVATE= \
    -DWLROOTS_DMABUF_WAIT_TEST -I"$WORK" -I"$WLR/include" \
    $(pkg-config --cflags wayland-server pixman-1) \
    "$ROOT/scripts/wlroots-dmabuf-regression.c" -o "$WORK/wait-regression" \
    $(pkg-config --libs wayland-server pixman-1)
  "$WORK/wait-regression"
  "${CC:-cc}" -std=gnu11 -Wall -Werror -Wno-unused-parameter -fsyntax-only \
    -D_GNU_SOURCE -DWLR_USE_UNSTABLE -DWLR_PRIVATE= -I"$WLR/include" \
    $(pkg-config --cflags wayland-server pixman-1 libdrm) \
    "$WLR/render/pixman/dmabuf.c" "$WLR/render/pixman/dmabuf_wait.c" \
    "$WLR/render/pixman/renderer.c" "$WLR/render/pixman/pass.c" \
    "$WLR/types/wlr_compositor.c"
  echo 'PASS: full importer/waiter/renderer/pass/compositor translation units pass real-header syntax checks'
elif [[ "${WLROOTS_DMABUF_TEST_WAYLAND:-auto}" == 1 ]]; then
  echo 'FAIL: Wayland event-loop tests require Linux and wayland-server/pixman/libdrm development files' >&2
  exit 1
else
  echo 'SKIP: real Wayland event-loop tests (run on Alpine with WLROOTS_DMABUF_TEST_WAYLAND=1)'
fi

# Guard the paths that determine Phoc's protocol advertisement and safe fallback.
grep -q 'WLR_BUFFER_CAP_DMABUF.*renderer->drm_fd >= 0' "$WLR/render/pixman/renderer.c"
grep -q 'return &renderer->dmabuf_formats;' "$WLR/render/pixman/renderer.c"
grep -q 'get_drm_fd = pixman_get_drm_fd' "$WLR/render/pixman/renderer.c"
grep -q 'renderer_impl, WLR_BUFFER_CAP_DATA_PTR);' "$WLR/render/pixman/renderer.c"
grep -q 'pixman_renderer_create_with_drm_fd(pixman_fd)' "$WLR/render/wlr_renderer.c"
grep -q 'set_check_dmabuf_callback(linux_dmabuf, check_import_pixman, check)' "$WLR/types/wlr_linux_dmabuf_v1.c"
grep -q 'pass->failed |= !pixman_dmabuf_buffer_ok' "$WLR/render/pixman/pass.c"
grep -q 'return pixman_dmabuf_buffer_ok(texture->buffer);' "$WLR/render/pixman/renderer.c"
grep -q '!pixman_dmabuf_lock_surface(surface)' "$WLR/types/wlr_compositor.c"
grep -q 'pixman_dmabuf_get_mapping(buffer, &data, &drm_format, &stride)' "$WLR/render/pixman/renderer.c"
grep -q 'if (!pinecone_pixman_prepare_output_commit())' "$WLR/types/output/output.c"
printf '%s\n' 'PASS: base + importer + ownership patches apply with zero fuzz; advertisement, import/commit readiness, metadata-only image creation and checked pre-backend commit wiring present'
