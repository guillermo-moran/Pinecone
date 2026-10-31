#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
  echo 'usage: sh test-path.sh EXACT-UNPATCHED-EDITOR-50.1-SOURCE NEW-OUTPUT' >&2
  exit 2
fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source=$(realpath "$1")
expected=983c5c958086a2e2cbd87a709dbbdec84bb34cdb142cb4a2fd5dff67ceb92e08
actual=$(sha256sum "$source/src/editor-path.c")
test "${actual%% *}" = "$expected" || { echo 'unexpected editor source bytes' >&2; exit 1; }
mkdir "$2"
out=$(realpath "$2")
mkdir -p "$out/original/src" "$out/patched/src"
cp "$source/src/editor-path.c" "$source/src/editor-path-private.h" "$out/original/src/"
cp "$source/src/editor-path.c" "$source/src/editor-path-private.h" "$out/patched/src/"
patch --batch --fuzz=0 -p1 -d "$out/patched" -i "$src/editor-path-literal.patch"
cc -std=gnu11 -O2 -g -Wall -Wextra -Werror $(pkg-config --cflags gio-2.0) \
  -I"$src/path-test-config" -D_editor_path_expand=reference_expand \
  -D_editor_path_collapse=reference_collapse -D_editor_get_portal_host_path=reference_portal \
  -Dwordexp=counted_wordexp -c "$out/original/src/editor-path.c" -o "$out/original.o"
cc -std=gnu11 -O2 -g -Wall -Wextra -Werror $(pkg-config --cflags gio-2.0) \
  -I"$src/path-test-config" -c "$out/patched/src/editor-path.c" -o "$out/patched.o"
nm -u "$out/patched.o" >"$out/patched-imports.txt"
if grep -Eq 'wordexp|wordfree|fork|spawn|exec' "$out/patched-imports.txt"; then
  echo 'patched path helper still imports process/expansion APIs' >&2
  exit 1
fi
cc -std=gnu11 -O2 -g -Wall -Wextra -Werror $(pkg-config --cflags gtk4) \
  "$src/test-path.c" "$out/original.o" "$out/patched.o" \
  $(pkg-config --libs gtk4) -o "$out/test-path"
HOME=/tmp/pinecone-path-home "$out/test-path" >"$out/plain-home.log" 2>&1
HOME='/tmp/pinecone path home' "$out/test-path" >"$out/space-home.log" 2>&1
HOME=/ "$out/test-path" >"$out/root-home.log" 2>&1
sha256sum "$src/editor-path-literal.patch" "$out/patched/src/editor-path.c" >"$out/SHA256SUMS"
printf 'Literal path differential and edit-notification tests passed: %s\n' "$out"
