#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:-${PHOC_SOURCE_ARCHIVE:-}}"
[[ $# -le 1 ]] || { echo "Usage: $0 [phoc-0.57.0.tar.xz]" >&2; exit 1; }
if [[ "$(uname -s)" != Linux ]]; then
  instance="${PINECONE_CACHE_LIMA_INSTANCE:-pinecone-builder}"
  if [[ -n "$ARCHIVE" ]]; then
    exec limactl shell "$instance" env \
      PINECONE_PIXMAN_REGRESSION_CASE="${PINECONE_PIXMAN_REGRESSION_CASE:-}" \
      PINECONE_PIXMAN_TEST_SANITIZERS="${PINECONE_PIXMAN_TEST_SANITIZERS:-}" \
      bash "$ROOT/scripts/run-pixman-bridge-regressions.sh" --archive-stdin < "$ARCHIVE"
  fi
  exec limactl shell "$instance" env \
    PINECONE_PIXMAN_REGRESSION_CASE="${PINECONE_PIXMAN_REGRESSION_CASE:-}" \
    PINECONE_PIXMAN_TEST_SANITIZERS="${PINECONE_PIXMAN_TEST_SANITIZERS:-}" \
    bash "$ROOT/scripts/run-pixman-bridge-regressions.sh"
fi
[[ "$(uname -m)" == aarch64 ]] || { echo 'Native AArch64 Linux is required' >&2; exit 1; }
WORK="$(mktemp -d /tmp/pinecone-pixman-regressions.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
flags=(-O2 -Wall -Wextra -Werror -pthread)
if [[ -n "$ARCHIVE" ]]; then
  [[ "$ARCHIVE" != --archive-stdin ]] || ARCHIVE=-
  tar -xJf "$ARCHIVE" -C "$WORK" phoc-0.57.0/subprojects/wlroots-0.20.x
  WLR="$WORK/phoc-0.57.0/subprojects/wlroots-0.20.x"
  for name in wlroots-pinecone-0.20.2.patch wlroots-pinecone-dmabuf.patch; do
    patch -s -d "$WLR" -p1 < "$ROOT/scripts/patches/$name"
  done
  patch -s -F 0 -d "$WLR" -p1 < "$ROOT/scripts/patches/wlroots-pinecone-ownership.patch"
  # Compile the actual patched commit function, not a parallel model of its order.
  sed -n '/^bool wlr_output_commit_state(/,/^}/p' "$WLR/types/output/output.c" > "$WORK/wlroots-output-commit.inc"
  flags+=(-DPINECONE_TEST_WLROOTS_COMMIT -I"$WORK")
fi
if [[ "${PINECONE_PIXMAN_TEST_SANITIZERS:-}" == undefined-trap ]]; then
  flags+=(-g -fsanitize=undefined -fsanitize-undefined-trap-on-error)
elif [[ -n "${PINECONE_PIXMAN_TEST_SANITIZERS:-}" ]]; then
  flags+=(-g -fno-omit-frame-pointer "-fsanitize=$PINECONE_PIXMAN_TEST_SANITIZERS")
fi
cc "${flags[@]}" "$ROOT/scripts/pixman-bridge-regression.c" -ldl -o "$WORK/test"
"$WORK/test"
