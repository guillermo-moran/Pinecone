#!/usr/bin/env python3
"""Create or verify the tested Pinecone Cairo runtime overlay's provenance."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE_SHA512 = "863679f817ed67dc2c916c035d740916e27e7e69c04fca63936e37d274e7f4c79848d16c8f7c481798864602e8847c489f698df89b785cbc576c925dbd513316"
INPUTS = (
    "scripts/patches/cairo-pinecone-cpu-access.patch",
    "scripts/build-pinecone-cairo.sh",
    "scripts/cairo-runtime-manifest.py",
    "scripts/run-cairo-access-regressions.sh",
    "scripts/pixman-cairo-access-regression.c",
    "scripts/rootfs/pinecone-pixman.h",
)
LIBRARIES = tuple(f"lib{name}.so.2.11804.4" for name in
                  ("cairo", "cairo-gobject", "cairo-script-interpreter"))


def digest(path, algorithm="sha256"):
    checksum = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def expected(output):
    libraries = {}
    for name in LIBRARIES:
        path = output / name
        if path.is_symlink():
            raise ValueError(f"Real library must not be a symlink: {name}")
        with path.open("rb") as stream:
            header = stream.read(20)
        if (header[:6] != b"\x7fELF\x02\x01" or
                int.from_bytes(header[16:18], "little") != 3 or
                int.from_bytes(header[18:20], "little") != 183):
            raise ValueError(f"Not an aarch64 ELF shared library: {name}")
        link = output / name.removesuffix(".11804.4")
        if not link.is_symlink() or str(link.readlink()) != name:
            raise ValueError(f"Missing or incorrect runtime symlink: {link.name}")
        libraries[name] = digest(path)
    archive = ROOT / "artifacts/cairo-source/cairo-1.18.4.tar.xz"
    if archive.exists() and digest(archive, "sha512") != SOURCE_SHA512:
        raise ValueError("Cairo source archive checksum mismatch")
    return {
        "schema": "pinecone-cairo-runtime-v1",
        "cairo_version": "1.18.4",
        "architecture": "aarch64-linux-musl",
        "source_sha512": SOURCE_SHA512,
        "inputs_sha256": {name: digest(ROOT / name) for name in INPUTS},
        "libraries_sha256": libraries,
        "required_bridge_symbols": [
            "pinecone_pixman_begin_cpu_access_flags",
            "pinecone_pixman_end_cpu_access",
            "pinecone_pixman_get_data_escaping",
        ],
        "validation": "Cairo ownership hooks and stock pixel comparison passed",
    }


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("create", "verify"):
        raise ValueError("usage: cairo-runtime-manifest.py create|verify OVERLAY_DIR")
    output = Path(sys.argv[2])
    manifest = output / "manifest.json"
    current = expected(output)
    if sys.argv[1] == "create":
        # The builder calls this only after the integration test succeeds.
        manifest.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
    elif json.loads(manifest.read_text()) != current:
        raise ValueError("Stale Cairo overlay: provenance or library content changed; rebuild required")
    print(f"Cairo runtime manifest {sys.argv[1]}: {manifest}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
