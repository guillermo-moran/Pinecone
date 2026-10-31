#!/bin/sh
set -eu
if [ "$#" -ne 3 ]; then
  echo 'usage: sh test-wait.sh TRACE-RUNTIME WAIT-LIBRARY-DIRECTORY NEW-OUTPUT' >&2
  exit 2
fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime=$(realpath "$1")
wait=$(realpath "$2")
mkdir "$3"
out=$(realpath "$3")
cc -std=gnu11 -O2 -Wall -Wextra -Werror -Wshadow -fPIC -shared -DPC_WAIT_BACKEND \
  $(pkg-config --cflags gtk4) -I"$src" "$src/test-wait.c" \
  $(pkg-config --libs gtk4) -Wl,-soname,libwait-fixture.so -o "$out/libwait-fixture.so"
cc -std=gnu11 -O2 -Wall -Wextra -Werror -Wshadow $(pkg-config --cflags gtk4) \
  -I"$src" "$src/test-wait.c" -L"$out" -lwait-fixture \
  $(pkg-config --libs gtk4) -L"$runtime" -lpinecone-text-trace \
  -Wl,-rpath,'$ORIGIN' -o "$out/test-wait"
for enabled in 0 1; do
  PINECONE_TEXT_INSERTION_TRACE="$enabled" \
    LD_LIBRARY_PATH="$out:$runtime:${LD_LIBRARY_PATH:-}" \
    LD_PRELOAD="$wait/libpinecone-text-wait.so" "$out/test-wait" >"$out/test-$enabled.log" 2>&1
done
test ! -s "$out/test-0.log"
python3 "$src/analyze-wait.py" "$out/test-1.log" >"$out/report.json"
grep -q 'name=gtk_application_inhibit ' "$out/test-1.log"
grep -q 'detail=Inhibit service=org.example.Test interface=org.example.Inhibit arg=123 result=1' "$out/test-1.log"
grep -q 'name=g_cond_wait_until ' "$out/test-1.log"
grep -q 'name=g_cond_wait ' "$out/test-1.log"
test "$(grep -c 'name=g_poll ' "$out/test-1.log")" = 1
if grep -q 'private-' "$out/test-1.log"; then echo 'payload leaked' >&2; exit 1; fi
if grep -q private_path "$out/test-1.log"; then echo 'object path leaked' >&2; exit 1; fi
printf 'Wait probe forwarding/privacy checks passed: %s\n' "$out"
