#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/pinecone-gtk-frame-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
read -r -a CFLAGS_PC <<<"$(pkg-config --cflags gtk4 pangocairo)"
read -r -a LIBS_PC <<<"$(pkg-config --libs gtk4 pangocairo)"
cc -O2 -Wall -Wextra -Werror -std=c11 "${CFLAGS_PC[@]}" \
    -fPIC -shared "$ROOT/scripts/guest-gtk-latency.c" \
    -ldl "${LIBS_PC[@]}" -o "$WORK/probe.so"
cc -O2 -Wall -Wextra -Werror -std=c11 -DPINECONE_PROFILE_LAUNCHER \
    "$ROOT/scripts/guest-gtk-latency.c" -o "$WORK/launcher"
cc -O2 -Wall -Wextra -Werror -std=c11 "${CFLAGS_PC[@]}" \
    "$ROOT/scripts/gtk-frame-profile-regression.c" \
    -ldl "${LIBS_PC[@]}" -o "$WORK/test"
"$WORK/test" > "$WORK/test.log"
python3 "$ROOT/scripts/analyze-gtk-latency.py" "$WORK/test.log" > /dev/null
cat "$WORK/test.log"
cc -O1 -g -Wall -Wextra -Werror -std=c11 -fsanitize=undefined \
    -fsanitize-undefined-trap-on-error "${CFLAGS_PC[@]}" \
    "$ROOT/scripts/gtk-frame-profile-regression.c" \
    -ldl "${LIBS_PC[@]}" -o "$WORK/test-ubsan"
"$WORK/test-ubsan" > "$WORK/test-ubsan.log"
python3 "$ROOT/scripts/analyze-gtk-latency.py" "$WORK/test-ubsan.log" > /dev/null
cat "$WORK/test-ubsan.log"
