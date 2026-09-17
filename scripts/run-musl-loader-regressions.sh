#!/usr/bin/env bash
set -euo pipefail

# Run on native Alpine/aarch64 with the candidate loader, without installing it.
LOADER="${1:?usage: run-musl-loader-regressions.sh /path/to/ld-musl-aarch64.so.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="${CC:-cc}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_check() {
  if ! "$@" 2>"$WORK/stderr"; then
    cat "$WORK/stderr" >&2
    return 1
  fi
  cat "$WORK/stderr" >&2
  case "${PINECONE_MUSL_EXPECT_STATS:-}" in
    1)
      python3 - "$ROOT/musl-loader-regression" "$WORK/stderr" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
sys.dont_write_bytecode = True
from measure import parse_stats
parse_stats(Path(sys.argv[2]).read_text())
PY
      ;;
    0) ! grep -q '^pinecone-musl-startup ' "$WORK/stderr" ;;
    "") ;;
    *) echo "PINECONE_MUSL_EXPECT_STATS must be 0 or 1" >&2; return 2 ;;
  esac
}

for hash in gnu sysv both; do
  for pie in -pie -no-pie; do
    mode=(-fPIE -pie)
    [[ "$pie" == -pie ]] || mode=(-fno-PIE -no-pie)
    flags=(-O2 -Wall -Wextra -Werror "-Wl,--hash-style=$hash")
    "$CC" "${flags[@]}" -fPIC -shared "$ROOT/musl-loader-regression/provider.c" \
      -Wl,--version-script="$ROOT/musl-loader-regression/versions.map" \
      -Wl,-soname,libprovider.so -o "$WORK/libprovider.so"
    "$CC" "${flags[@]}" -fPIC -shared "$ROOT/musl-loader-regression/later.c" \
      -Wl,-soname,liblater.so -o "$WORK/liblater.so"
    "$CC" "${flags[@]}" -fPIC -shared "$ROOT/musl-loader-regression/plugin.c" \
      -L"$WORK" -lprovider -o "$WORK/plugin.so"
    "$CC" "${flags[@]}" -fPIC -shared "$ROOT/musl-loader-regression/preload.c" \
      -o "$WORK/preload.so"
    "$CC" "${flags[@]}" "${mode[@]}" "$ROOT/musl-loader-regression/main.c" \
      -L"$WORK" -Wl,--no-as-needed -lprovider -llater -pthread -ldl -o "$WORK/check"
    if [[ "$pie" == -no-pie ]]; then
      readelf -r "$WORK/check" > "$WORK/relocations"
      grep -q 'R_AARCH64_COPY.*provider_value' "$WORK/relocations"
    fi
    echo "hash=$hash executable=$pie"
    run_check "$LOADER" --library-path "$WORK:/lib:/usr/lib" \
      "$WORK/check" "$WORK/plugin.so" 28 61
    run_check "$LOADER" --library-path "$WORK:/lib:/usr/lib" --preload "$WORK/preload.so" \
      "$WORK/check" "$WORK/plugin.so" 43 81
  done
done
