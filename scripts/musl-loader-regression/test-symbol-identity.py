#!/usr/bin/env python3
"""Exercise the patched bootstrap comparator, not a separately copied model."""
from pathlib import Path
import os
import re
import shlex
import subprocess
import sys
import tempfile


def main():
    source = Path(sys.argv[1]).read_text()
    helper = re.search(r"static int dl_strcmp\(.*?^\}", source, re.S | re.M)
    if helper is None:
        raise SystemExit("loader comparator missing")
    harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
HELPER
static int sign(int n) { return (n > 0) - (n < 0); }
static void check(const char *a, const char *b) {
    assert(sign(dl_strcmp(a, b)) == sign(strcmp(a, b)));
    assert(sign(dl_strcmp(b, a)) == sign(strcmp(b, a)));
    assert(dl_strcmp(a, a) == 0);
    assert(dl_strcmp(b, b) == 0);
}
int main(void) {
    char a[1025], b[1025];
    uint32_t state = 19;
    for (size_t n = 0; n <= 1024; n++) {
        for (size_t i = 0; i < n; i++) {
            state = state * 1664525U + 1013904223U;
            a[i] = (char)(1 + state % 255);
        }
        a[n] = 0;
        memcpy(b, a, n + 1);
        check(a, b);
        for (size_t i = 0; i < n; i++) {
            unsigned char saved = (unsigned char)b[i];
            b[i] = (char)(saved == 255 ? 1 : saved + 1);
            check(a, b);
            b[i] = 0;
            check(a, b);
            b[i] = (char)saved;
        }
    }
    long page = sysconf(_SC_PAGESIZE);
    assert(page > 1024);
    char *maps[2];
    for (int i = 0; i < 2; i++) {
        maps[i] = mmap(NULL, (size_t)page * 3, PROT_NONE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        assert(maps[i] != MAP_FAILED);
        assert(mprotect(maps[i] + page, (size_t)page,
                        PROT_READ | PROT_WRITE) == 0);
    }
    for (size_t n = 0; n <= 1024; n++) {
        char *left = maps[0] + page * 2 - n - 1;
        char *right = maps[1] + page * 2 - n - 1;
        memset(left, 'x', n); left[n] = 0;
        memset(right, 'x', n); right[n] = 0;
        check(left, right);
    }
    for (int i = 0; i < 2; i++)
        assert(munmap(maps[i], (size_t)page * 3) == 0);
    puts("loader string identity, distinct strings, high bytes, prefixes and guard pages: PASS");
}
'''.replace("HELPER", helper.group())
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        (path / "check.c").write_text(harness)
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
            "-O2", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
            "-fno-sanitize-recover=all", str(path / "check.c"),
            "-o", str(path / "check")], check=True)
        subprocess.run([str(path / "check")], check=True)


if __name__ == "__main__":
    main()
