#!/usr/bin/env python3
"""Emit a diagnostic-only unified patch; never modify the supplied source tree."""
import argparse
import difflib
import hashlib
from pathlib import Path
import re
import sys


FILES = {
    "editor": {
        "src/editor-document.c": (
            "670f7a2a3fdc3a0d695548e3c2ba76f186c647132f9f29719ba2f618c7593ab8",
            ["editor_document_insert_text", "editor_document_delete_range",
             "editor_document_changed", "editor_document_guess_content_type",
             "editor_document_dup_title", "editor_document_cursor_moved"]),
        "src/editor-page.c": (
            "11deebb51a0848ab0f29e373b9d490134361b2fc52fd2e7f8ff743ede3f33bb9",
            ["editor_page_document_modified_changed_cb",
             "editor_page_document_notify_title_cb", "editor_page_document_cursor_moved_cb"]),
        "src/editor-session.c": (
            "e5ba478ace73a46d20a3e76a8905cf6adc84496cba846b56e485e2cbb46be8f2",
            ["editor_session_document_changed_cb", "_editor_session_mark_dirty"]),
    },
    "sourceview": {
        "gtksourceview/gtksourcebuffer.c": (
            "4393a86a3769a06ebf6e4184b084c9fd7f4bdbee968f97b94b884efdaa6b0de8",
            ["gtk_source_buffer_real_insert_text", "gtk_source_buffer_real_delete_range",
             "gtk_source_buffer_content_inserted", "cursor_moved",
             "queue_bracket_highlighting_update"]),
        "gtksourceview/gtksourcecontextengine.c": (
            "16f6f6f1ef0eac8c039f1ee1be60713f2b00359cb77fe7d4003320b3f20cefec",
            ["gtk_source_context_engine_text_inserted", "gtk_source_context_engine_text_deleted",
             "gtk_source_context_engine_update_highlight", "update_syntax"]),
    },
}
ROOTS = {"editor_document_insert_text", "editor_document_delete_range"}


def transform(path, source, digest, functions):
    if hashlib.sha256(source.encode()).hexdigest() != digest:
        raise ValueError(f"{path}: source hash mismatch; refusing unknown/modified source")
    result = source
    for name in functions:
        pattern = rf"(?m)^{re.escape(name)}\s*\([^;{{}}]*\)\n\{{\n"
        matches = list(re.finditer(pattern, result))
        if len(matches) != 1:
            raise ValueError(f"{path}: expected one definition of {name}")
        pos = matches[0].end()
        root = "0"
        if name in ROOTS:
            # Restoration is itself a measured multi-second stall. Include it.
            pos = result.index("  if (self->loading)\n", pos)
            root = "1"
        elif name in {"gtk_source_buffer_real_insert_text", "gtk_source_buffer_real_delete_range"}:
            # Also usable with the stock editor; a patched editor stays the root.
            root = "1"
        result = result[:pos] + f'  PC_TEXT_SCOPE ("{name}", {root});\n' + result[pos:]
    if path == "src/editor-document.c":
        old = "g_object_notify_by_pspec (G_OBJECT (self), properties [PROP_TITLE]);"
        if result.count(old) != 2:
            raise ValueError("unexpected title notification sites")
        result = result.replace(old, f'PC_TEXT_CALL ("document.title-notify", {old[:-1]});')
    if path == "gtksourceview/gtksourcebuffer.c":
        for operation, args in [("insert_text", "buffer, iter, text, len"),
                                ("delete_range", "buffer, start, end")]:
            old = f"GTK_TEXT_BUFFER_CLASS (gtk_source_buffer_parent_class)->{operation} ({args});"
            if result.count(old) != 1:
                raise ValueError(f"unexpected parent {operation} sites")
            result = result.replace(old, f'PC_TEXT_CALL ("sourceview.gtk-parent.{operation}", {old[:-1]});')
    # config.h must remain the first include (feature macros).
    include = '#include "config.h"\n'
    if result.count(include) != 1:
        raise ValueError(f"{path}: missing unique config include")
    return result.replace(include, include + '#include "pinecone-text-trace.h"\n')


def make_patch(component, root):
    output = []
    for path, (digest, functions) in FILES[component].items():
        source = (root / path).read_bytes().decode("utf-8")
        changed = transform(path, source, digest, functions)
        output.extend(difflib.unified_diff(source.splitlines(True), changed.splitlines(True),
                                           fromfile="a/" + path, tofile="b/" + path))
    return "".join(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=FILES)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    try:
        patch = make_patch(args.component, args.source)
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")
    sys.stdout.write(patch)


if __name__ == "__main__":
    main()
