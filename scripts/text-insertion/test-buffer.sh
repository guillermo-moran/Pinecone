#!/bin/sh
# User-run integration check against an explicitly selected Linux package prefix.
set -eu
if [ "$#" -ne 2 ]; then
  echo 'usage: sh test-buffer.sh NEW-OUTPUT-DIRECTORY TRACE-LIBRARY-DIRECTORY' >&2
  exit 2
fi
[ "$(uname -s)" = Linux ] || { echo 'Linux integration environment required' >&2; exit 1; }
[ "$(pkg-config --modversion gtksourceview-5)" = 5.20.0 ] || {
  echo 'expected GtkSourceView 5.20.0; select the matching pkg-config prefix' >&2
  exit 1
}
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
trace=$(CDPATH= cd -- "$2" && pwd)
test -f "$trace/libpinecone-text-trace.so"
mkdir "$1"
out=$(CDPATH= cd -- "$1" && pwd)
# pkg-config output intentionally expands into compiler arguments.
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -I"$src" \
  $(pkg-config --cflags gtksourceview-5) "$src/test-buffer.c" \
  $(pkg-config --libs gtksourceview-5) -L"$trace" -lpinecone-text-trace \
  -Wl,-rpath,"$trace" -o "$out/test-buffer"
PINECONE_TEXT_INSERTION_TRACE=0 "$out/test-buffer" >"$out/disabled.log" 2>&1
PINECONE_TEXT_INSERTION_TRACE=1 "$out/test-buffer" >"$out/enabled.log" 2>&1
python3 "$src/analyze.py" "$out/enabled.log" >"$out/trace.json"
PINECONE_TEXT_INSERTION_TRACE=1 PC_TEXT_TEST_STANDALONE=1 \
  "$out/test-buffer" >"$out/standalone.log" 2>&1
python3 "$src/analyze.py" "$out/standalone.log" >"$out/standalone.json"
# Refuse a green integration result if the selected sourceview was not patched.
grep -q 'name=gtk_source_buffer_real_insert_text ' "$out/enabled.log"
grep -q 'name=gtk_source_buffer_real_delete_range ' "$out/enabled.log"
grep -q 'parent=0 .*name=gtk_source_buffer_real_insert_text ' "$out/standalone.log"
printf 'Buffer regression passed; logs in %s\n' "$out"
