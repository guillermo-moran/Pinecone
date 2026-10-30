#!/usr/bin/env python3
"""Check the actual loader helper, including the overwritten GNU chain bit."""
from pathlib import Path
import os
import re
import shlex
import subprocess
import sys
import tempfile


def main():
    source = Path(sys.argv[1]).read_text()
    helper = re.search(
        r"static int startup_sym_index_gnu_hash\(.*?^\}", source, re.S | re.M
    )
    if helper is None:
        raise SystemExit("GNU hash recovery helper missing")
    lookup = re.search(r"static Sym \*gnu_lookup\(.*?^\}", source, re.S | re.M)
    if lookup is None:
        raise SystemExit("GNU lookup function missing")
    harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
HELPER
typedef struct { uint32_t st_name; } Sym;
struct dso { int16_t *versym; char *strings; Sym *syms; };
static unsigned comparisons;
static int counted_strcmp(const char *a, const char *b) {
    comparisons++;
    return strcmp(a, b);
}
#define strcmp counted_strcmp
LOOKUP
#undef strcmp
static void check_lookup(void) {
    /* One bucket with two equal-hash symbols; no bloom words are consulted. */
    uint32_t table[] = {1, 1, 0, 0, 1, 100, 101};
    char names[] = "\0alpha\0alpha\0bravo\0";
    Sym syms[] = {{0}, {1}, {7}};
    int16_t versions[] = {0, 0, 0};
    struct dso dso = {versions, names, syms};
    comparisons = 0;
    assert(gnu_lookup(100, table, &dso, names + 1) == syms + 1);
    assert(comparisons == 0);
    /* Earlier equal names must win even when the later pointer is identical. */
    comparisons = 0;
    assert(gnu_lookup(100, table, &dso, names + 7) == syms + 1);
    assert(comparisons == 1);
    versions[1] = -1;
    comparisons = 0;
    assert(gnu_lookup(100, table, &dso, names + 7) == syms + 2);
    assert(comparisons == 0);
    assert(gnu_lookup(100, table, &dso, "alpha") == syms + 2);
    versions[2] = -1;
    assert(gnu_lookup(100, table, &dso, names + 7) == NULL);
    dso.versym = NULL;
    assert(gnu_lookup(100, table, &dso, names + 7) == syms + 1);
    syms[1].st_name = 13;
    assert(gnu_lookup(100, table, &dso, names + 7) == syms + 2);
    assert(gnu_lookup(100, table, &dso, "absent") == NULL);
    assert(gnu_lookup(102, table, &dso, names + 7) == NULL);
    table[4] = 0;
    assert(gnu_lookup(100, table, &dso, names + 7) == NULL);
}
static void check(uint32_t hash, uint32_t buckets) {
    for (unsigned end = 0; end < 2; end++) {
        uint32_t recovered = 0x12345678;
        int ok = startup_sym_index_gnu_hash((hash & ~1U) | end,
                                            hash % buckets, buckets, &recovered);
        if (buckets == 1) {
            assert(!ok && recovered == 0x12345678);
        } else {
            assert(ok && recovered == hash);
        }
    }
}
int main(void) {
    check_lookup();
    const uint32_t counts[] = {1, 2, 3, 4, 17, 65521, 0x80000000U, UINT32_MAX};
    for (unsigned c = 0; c < sizeof counts / sizeof counts[0]; c++) {
        for (uint32_t h = 0; h < 65536; h++) {
            check(h, counts[c]);
            check(UINT32_MAX - h, counts[c]);
        }
    }
    uint32_t state = 17;
    for (unsigned n = 0; n < 200000; n++) {
        state = state * 1664525U + 1013904223U;
        uint32_t hash = state;
        state = state * 1664525U + 1013904223U;
        check(hash, state ? state : 1);
    }
    uint32_t output = 123;
    assert(!startup_sym_index_gnu_hash(0, 0, 0, &output));
    assert(!startup_sym_index_gnu_hash(0, 3, 3, &output));
    assert(!startup_sym_index_gnu_hash(0, 2, 3, &output));
    assert(output == 123);
    puts("GNU hash recovery: 2,497,152 valid cases and invalid/ambiguous guards pass");
    puts("GNU lookup: identity, duplicates, versions, collisions and misses pass");
}
'''.replace("HELPER", helper.group()).replace("LOOKUP", lookup.group())
    with tempfile.TemporaryDirectory(prefix="pinecone-gnu-hash-") as directory:
        path = Path(directory)
        (path / "test.c").write_text(harness)
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
            "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            "-fsanitize=undefined", str(path / "test.c"), "-o", str(path / "test")
        ], check=True)
        subprocess.run([str(path / "test")], check=True)


if __name__ == "__main__":
    main()
