#!/usr/bin/env python3
"""On Linux, check the diagnostic patch against pristine GTK 4.22.4 source."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def check(source):
    if not sys.platform.startswith("linux"):
        raise SystemExit("Run in the Linux builder: this checks guest ELF weak-symbol semantics")
    patch = Path(__file__).with_name("patches") / "gtk4-frame-profile.patch"
    names = ("gskrenderer.c", "gskcairorenderer.c", "gsktexturenode.c")
    with tempfile.TemporaryDirectory(prefix="gtk-frame-patch-") as temporary:
        root = Path(temporary)
        (root / "gsk").mkdir()
        for name in names:
            shutil.copyfile(source / "gsk" / name, root / "gsk" / name)
        subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-d", str(root),
                        "-i", str(patch.resolve())], check=True)
        marks = []
        for name in names:
            original = (source / "gsk" / name).read_text()
            patched = (root / "gsk" / name).read_text().splitlines(keepends=True)
            restored = []
            for line in patched:
                if line.strip() == '#include "pineconeframeprivate.h"':
                    continue
                if line.strip().startswith("PINECONE_FRAME_MARK ("):
                    marks.append(line.strip())
                    continue
                restored.append(line)
            assert "".join(restored) == original, f"Non-diagnostic changes in {name}"
        for stage in ("gsk_diff", "cairo_begin", "cairo_draw", "cairo_end",
                      "texture_diff", "texture_download"):
            for entering in (0, 1):
                assert marks.count(f'PINECONE_FRAME_MARK ("{stage}", {entering});') == 1
        assert len(marks) == 12
        fixture = root / "hooks.c"
        fixture.write_text('''#include <assert.h>
#define G_STMT_START do
#define G_STMT_END while (0)
#include "gsk/pineconeframeprivate.h"
#ifdef HAVE_HOOK
extern int calls;
#endif
int main(void) {
    PINECONE_FRAME_MARK("test", 1);
    PINECONE_FRAME_MARK("test", 0);
#ifdef HAVE_HOOK
    assert(calls == 3);
#endif
    return 0;
}
''')
        hook = root / "hook.c"
        hook.write_text('''#include <assert.h>
int calls;
void pinecone_gtk_frame_mark(const char *stage, int entering) {
    assert(stage[0] == 't');
    calls += entering ? 1 : 2;
}
''')
        for flags in ([], ["-DHAVE_HOOK"]):
            binary = root / "hooks"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                            *flags, str(fixture), *([str(hook)] if flags else []),
                            "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
    print("PASS: zero-fuzz application; rendering source unchanged after stripping marks; hooks present/absent")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("gtk_source", type=Path)
    check(parser.parse_args().gtk_source)
