#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${LINUX_VERSION:-6.18.38}"
ARCHIVE="${1:-${LINUX_SOURCE_ARCHIVE:-$ROOT/artifacts/linux-shell/linux-$VERSION.tar.xz}}"
if [[ $# -gt 1 || "${1:-}" == --help ]]; then
  echo "Usage: $0 [linux-$VERSION.tar.xz] (or set LINUX_SOURCE_ARCHIVE)" >&2
  echo 'TOUCH_TIMESTAMP_TEST_SANITIZE=undefined enables UBSan; 1 enables ASan/UBSan.' >&2
  [[ "${1:-}" == --help && $# -eq 1 ]] && exit 0
  exit 1
fi
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Missing kernel archive: $ARCHIVE" >&2
  echo "Usage: $0 /path/to/linux-$VERSION.tar.xz (no downloads or kernel builds are performed)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source/drivers/virtio"
SOURCE="$WORK/source/drivers/virtio/virtio_input.c"
# Start from the pristine archive, never mutate or trust an in-flight build tree.
tar -xOf "$ARCHIVE" "linux-$VERSION/drivers/virtio/virtio_input.c" > "$SOURCE"
if ! patch --batch --fuzz=0 -p1 -d "$WORK/source" \
    < "$ROOT/scripts/patches/linux-virtio-input-timestamps.patch" > "$WORK/patch.log" 2>&1; then
  cat "$WORK/patch.log" >&2
  exit 1
fi
if grep -Ei 'offset|fuzz|FAILED|reject' "$WORK/patch.log"; then
  echo 'Timestamp patch must apply without offsets or fuzz.' >&2
  exit 1
fi

# Compile production state, helpers, device gate and PM reset statements.
# The harness supplies only kernel API stubs and assertions, not timestamp logic.
awk '
  /^#define PINECONE_(INPUT_CLOCK|TIME_LO|TIME_HI) / { print; constants++ }
  /^struct virtio_input \{/ { block = "struct"; structures++ }
  /^static u64 virtinput_map_time\(/ { block = "function"; maps++ }
  /^static void virtinput_apply_time\(/ { block = "function"; applies++ }
  /^static bool virtinput_pinecone_time\(/ { block = "function"; parsers++ }
  block != "" {
    print
    if ((block == "struct" && /^};/) || (block == "function" && /^}/)) block = ""
    next
  }
  /vi->pinecone_timestamps =/ {
    print "static void configure_timestamp_gate(struct virtio_input *vi) {"
    gate = 1; gates++
  }
  gate {
    print
    if (/;$/) { print "}"; gate = 0 }
    next
  }
  /^static int virtinput_restore\(/ { restore = 1 }
  restore && /vi->clock_valid = false;/ {
    print "static void reset_timestamp_state(struct virtio_input *vi) {"
    reset = 1; resets++
  }
  reset {
    print
    if (/vi->last_time_ns = 0;/) { print "}"; reset = 0; restore = 0 }
    next
  }
  END {
    if (constants != 3 || structures != 1 || maps != 1 || applies != 1 ||
        parsers != 1 || gates != 1 || resets != 1 || block != "" || gate || reset)
      exit 1
  }
' "$SOURCE" > "$WORK/touch-timestamp-linux.inc" || {
  echo 'Cannot extract the expected production timestamp code; update the extractor for this kernel.' >&2
  exit 1
}

EXTRA=()
case "${TOUCH_TIMESTAMP_TEST_SANITIZE:-0}" in
  0) ;;
  1) EXTRA=(-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all) ;;
  undefined) EXTRA=(-fsanitize=undefined -fno-omit-frame-pointer -fno-sanitize-recover=all) ;;
  *) echo 'TOUCH_TIMESTAMP_TEST_SANITIZE must be 0, 1, or undefined' >&2; exit 1 ;;
esac
"${CC:-cc}" -std=c11 -g -Wall -Wextra -Werror \
  ${EXTRA[@]+"${EXTRA[@]}"} -I"$WORK" \
  "$ROOT/scripts/touch-timestamp-regression.c" -o "$WORK/touch-timestamp-regression"
"$WORK/touch-timestamp-regression"
echo "Touch timestamp regressions passed against patch-applied Linux $VERSION."
