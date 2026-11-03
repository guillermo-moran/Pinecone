#!/usr/bin/env python3
"""Create a LineageOS disk whose compressed system APEX files are pre-expanded.

The virtio_arm64only image ships most APEX packages as CAPEX files. Expanding
them in the emulated guest makes first boot spend minutes copying each package
to userdata. This tool performs the lossless CAPEX -> APEX extraction on the
host while preserving the complete system APEX set, including Android
Virtualization Framework. To fit the expanded packages in the fixed-size system
filesystem, the image substitutes the two large CJK font collections with the
existing Roboto font and omits the optional Device Diagnostics APK.

The source is never opened for writing. The output is an APFS copy-on-write
clone with only the extracted system logical partition written back into it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile


class PreparationError(RuntimeError):
    pass


CAPEX_KEEP_COMPRESSED: set[str] = set()


def run(command: list[str], *, accepted: tuple[int, ...] = (0,)) -> subprocess.CompletedProcess:
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode not in accepted:
        detail = result.stderr.strip() or result.stdout.strip()
        raise PreparationError(
            f"command failed ({result.returncode}): {' '.join(command)}\n{detail}"
        )
    return result


def find_tool(name: str, candidates: list[str]) -> str:
    configured = os.environ.get(name)
    if configured:
        resolved = shutil.which(configured) or configured
        if Path(resolved).is_file() and os.access(resolved, os.X_OK):
            return resolved
        raise PreparationError(f"{name} does not name an executable: {configured}")
    for candidate in candidates:
        resolved = shutil.which(candidate) or candidate
        if Path(resolved).is_file() and os.access(resolved, os.X_OK):
            return resolved
    raise PreparationError(f"missing required tool: {candidates[0]}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_image(inspector: Path, image: Path) -> dict:
    result = run([sys.executable, str(inspector), str(image), "--json"])
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise PreparationError("image inspector returned invalid JSON") from error


def extract_system(inspector: Path, image: Path, directory: Path) -> Path:
    run(
        [
            sys.executable,
            str(inspector),
            str(image),
            "--extract",
            "system",
            "--output-dir",
            str(directory),
        ]
    )
    return directory / "system.img"


def write_system_partition(output: Path, report: dict, system_image: Path) -> None:
    partition = next(
        (item for item in report["super"]["partitions"] if item["name"] == "system"),
        None,
    )
    if partition is None or len(partition["extents"]) != 1:
        raise PreparationError("system must be one linear logical-partition extent")
    extent = partition["extents"][0]
    if extent["targetType"] != 0 or extent["targetSource"] != 0:
        raise PreparationError("system is not a linear extent in the primary super device")
    expected_size = extent["numSectors"] * 512
    if system_image.stat().st_size != expected_size:
        raise PreparationError(
            f"system size changed: expected {expected_size}, got {system_image.stat().st_size}"
        )
    offset = (report["super"]["firstLBA"] + extent["targetData"]) * 512
    with output.open("r+b") as target, system_image.open("rb") as source:
        target.seek(offset)
        while chunk := source.read(8 * 1024 * 1024):
            target.write(chunk)
        target.flush()
        os.fsync(target.fileno())


def reclaim_system_space(debugfs: str, system_image: Path, work: Path) -> list[dict]:
    """Reclaim boot-safe payload space without changing the system APEX set."""
    fallback_font = work / "Roboto-Regular.ttf"
    run(
        [
            debugfs,
            "-R",
            f"dump /system/fonts/Roboto-Regular.ttf {fallback_font}",
            str(system_image),
        ]
    )
    context_file = work / "font-file-context"
    context_file.write_bytes(b"u:object_r:system_file:s0\0")
    trimmed: list[dict] = []
    for name in ("NotoSansCJK-Regular.ttc", "NotoSerifCJK-Regular.ttc"):
        path = f"/system/fonts/{name}"
        run([debugfs, "-w", "-R", f"rm {path}", str(system_image)])
        run([debugfs, "-w", "-R", f"write {fallback_font} {path}", str(system_image)])
        run(
            [
                debugfs,
                "-w",
                "-R",
                f"ea_set -f {context_file} -r {path} security.selinux",
                str(system_image),
            ]
        )
        trimmed.append(
            {
                "path": path,
                "replacement": "/system/fonts/Roboto-Regular.ttf",
                "reason": "retain a valid fallback font while reclaiming CJK collection space",
            }
        )

    context_file = work / "system-config-file-context"
    context_file.write_bytes(b"u:object_r:system_file:s0\0")
    for config_name in ("fonts.xml", "font_fallback.xml"):
        config_path = f"/system/etc/{config_name}"
        config_xml = work / config_name
        run(
            [
                debugfs,
                "-R",
                f"dump {config_path} {config_xml}",
                str(system_image),
            ]
        )
        font_tree = ET.parse(config_xml)
        font_root = font_tree.getroot()
        removed_families = 0
        for family in list(font_root.findall("family")):
            family_text = "".join(family.itertext())
            if any(
                name in family_text
                for name in ("NotoSansCJK-Regular.ttc", "NotoSerifCJK-Regular.ttc")
            ):
                font_root.remove(family)
                removed_families += 1
        if removed_families == 0:
            raise PreparationError(
                f"{config_name} has no CJK collection families to trim"
            )
        if any(
            name in "".join(font_root.itertext())
            for name in ("NotoSansCJK-Regular.ttc", "NotoSerifCJK-Regular.ttc")
        ):
            raise PreparationError(
                f"{config_name} still references a trimmed CJK collection"
            )
        ET.indent(font_tree, space="    ")
        font_tree.write(config_xml, encoding="utf-8", xml_declaration=True)

        run([debugfs, "-w", "-R", f"rm {config_path}", str(system_image)])
        run(
            [
                debugfs,
                "-w",
                "-R",
                f"write {config_xml} {config_path}",
                str(system_image),
            ]
        )
        run(
            [
                debugfs,
                "-w",
                "-R",
                f"set_inode_field {config_path} mode 0100644",
                str(system_image),
            ]
        )
        run(
            [
                debugfs,
                "-w",
                "-R",
                f"ea_set -f {context_file} -r {config_path} security.selinux",
                str(system_image),
            ]
        )
        trimmed.append(
            {
                "path": config_path,
                "replacement": None,
                "reason": (
                    f"remove {removed_families} fallback families that reference the "
                    "trimmed CJK collections"
                ),
            }
        )

    diagnostics = "/system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk"
    run([debugfs, "-w", "-R", f"rm {diagnostics}", str(system_image)])
    trimmed.append(
        {
            "path": diagnostics,
            "replacement": None,
            "reason": "optional hardware diagnostics UI is not used by the emulator",
        }
    )
    return trimmed


def preexpand_apex(
    debugfs: str,
    system_image: Path,
    work: Path,
) -> tuple[list[dict], list[dict]]:
    extracted_root = work / "system-files"
    extracted_root.mkdir()
    run(
        [
            debugfs,
            "-R",
            f"rdump /system/apex {extracted_root}",
            str(system_image),
        ]
    )
    apex_directory = extracted_root / "apex"
    capex_files = sorted(apex_directory.glob("*.capex"))
    if len(capex_files) < 20:
        raise PreparationError(
            f"expected the pinned compressed-APEX layout, found {len(capex_files)} CAPEX files"
        )

    if not (apex_directory / "com.android.virt.apex").is_file():
        raise PreparationError("expected com.android.virt.apex is missing")

    context_file = work / "system-file-context"
    context_file.write_bytes(b"u:object_r:system_file:s0\0")
    expanded: list[dict] = []
    kept_compressed: list[dict] = []
    for capex in capex_files:
        if capex.name in CAPEX_KEEP_COMPRESSED:
            kept_compressed.append(
                {
                    "path": f"/system/apex/{capex.name}",
                    "compressedBytes": capex.stat().st_size,
                    "sha256": sha256(capex),
                    "reason": "preserve system APEX set and filesystem headroom",
                }
            )
            continue
        with zipfile.ZipFile(capex) as archive:
            try:
                original_info = archive.getinfo("original_apex")
            except KeyError as error:
                raise PreparationError(f"{capex.name} has no original_apex") from error
            apex = work / capex.with_suffix(".apex").name
            with archive.open(original_info) as source, apex.open("wb") as target:
                shutil.copyfileobj(source, target, 8 * 1024 * 1024)
        with zipfile.ZipFile(apex) as archive:
            required = {"apex_payload.img", "apex_manifest.pb", "apex_pubkey"}
            if not required.issubset(archive.namelist()):
                raise PreparationError(f"invalid original APEX in {capex.name}")

        old_path = f"/system/apex/{capex.name}"
        new_path = f"/system/apex/{apex.name}"
        run([debugfs, "-w", "-R", f"rm {old_path}", str(system_image)])
        run([debugfs, "-w", "-R", f"write {apex} {new_path}", str(system_image)])
        run(
            [
                debugfs,
                "-w",
                "-R",
                f"ea_set -f {context_file} -r {new_path} security.selinux",
                str(system_image),
            ]
        )
        expanded.append(
            {
                "source": old_path,
                "output": new_path,
                "compressedBytes": capex.stat().st_size,
                "expandedBytes": apex.stat().st_size,
                "sha256": sha256(apex),
            }
        )
    missing_kept = CAPEX_KEEP_COMPRESSED - {Path(item["path"]).name for item in kept_compressed}
    if missing_kept:
        raise PreparationError(
            "expected compressed APEX packages are missing: " + ", ".join(sorted(missing_kept))
        )
    return expanded, kept_compressed


def force_art_interpreter(debugfs: str, system_image: Path, work: Path) -> dict:
    """Force zygote through ART's interpreter instead of boot.oat machine code."""
    build_prop = work / "system-build.prop"
    run(
        [
            debugfs,
            "-R",
            f"dump /system/build.prop {build_prop}",
            str(system_image),
        ]
    )
    original = build_prop.read_text()
    properties = {
        "dalvik.vm.execution-mode": "int:portable",
        "dalvik.vm.extra-opts": "-Xint",
        "dalvik.vm.usejit": "false",
    }
    retained = [
        line
        for line in original.splitlines()
        if line.split("=", 1)[0] not in properties
    ]
    retained.extend(f"{name}={value}" for name, value in properties.items())
    build_prop.write_text("\n".join(retained) + "\n")

    context_file = work / "system-build-prop-context"
    context_file.write_bytes(b"u:object_r:system_file:s0\0")
    run([debugfs, "-w", "-R", "rm /system/build.prop", str(system_image)])
    run(
        [
            debugfs,
            "-w",
            "-R",
            f"write {build_prop} /system/build.prop",
            str(system_image),
        ]
    )
    run(
        [
            debugfs,
            "-w",
            "-R",
            "set_inode_field /system/build.prop mode 0100600",
            str(system_image),
        ]
    )
    run(
        [
            debugfs,
            "-w",
            "-R",
            f"ea_set -f {context_file} -r /system/build.prop security.selinux",
            str(system_image),
        ]
    )
    return {
        "path": "/system/build.prop",
        "properties": properties,
        "reason": "Avoid the boot.oat zygote crash while the emulator's ART instruction mismatch is isolated",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="source LineageOS raw disk")
    parser.add_argument("output", type=Path, help="new pre-expanded raw disk")
    parser.add_argument(
        "--art-interpreter",
        action="store_true",
        help="force zygote and apps through ART's interpreter (-Xint)",
    )
    args = parser.parse_args()

    output_created = False
    try:
        source = args.source.resolve()
        output = args.output.resolve()
        if not source.is_file():
            raise PreparationError(f"source does not exist: {source}")
        if output.exists():
            raise PreparationError(f"refusing to overwrite existing output: {output}")
        if source == output:
            raise PreparationError("source and output must differ")

        script_directory = Path(__file__).resolve().parent
        inspector = script_directory / "inspect-lineageos-image.py"
        debugfs = find_tool(
            "LINEAGE_DEBUGFS", ["debugfs", "/opt/homebrew/opt/e2fsprogs/sbin/debugfs"]
        )
        e2fsck = find_tool(
            "LINEAGE_E2FSCK", ["e2fsck", "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck"]
        )
        report = inspect_image(inspector, source)

        with tempfile.TemporaryDirectory(prefix="arm64viz-preexpanded-apex-") as temporary:
            work = Path(temporary)
            system_image = extract_system(inspector, source, work / "partition")
            trimmed = reclaim_system_space(debugfs, system_image, work)
            expanded, kept_compressed = preexpand_apex(debugfs, system_image, work)
            art_interpreter = (
                force_art_interpreter(debugfs, system_image, work)
                if args.art_interpreter
                else None
            )
            run([e2fsck, "-fy", str(system_image)], accepted=(0, 1, 2))

            output.parent.mkdir(parents=True, exist_ok=True)
            run(["cp", "-c", str(source), str(output)])
            output_created = True
            write_system_partition(output, report, system_image)

        provenance = output.with_name(output.name + ".provenance.json")
        record = {
            "schemaVersion": 1,
            "source": str(source),
            "sourceSha256": sha256(source),
            "output": str(output),
            "expandedApex": expanded,
            "keptCompressedApex": kept_compressed,
            "removed": [],
            "trimmed": trimmed,
            "artInterpreter": art_interpreter,
        }
        provenance.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        print(f"created pre-expanded LineageOS disk: {output}")
        print(f"expanded {len(expanded)} CAPEX packages")
        print(f"kept {len(kept_compressed)} non-boot-critical CAPEX packages compressed")
        print("retained the complete system APEX set")
        print(f"wrote provenance: {provenance}")
    except (PreparationError, OSError, KeyError, TypeError, zipfile.BadZipFile) as error:
        if output_created:
            args.output.resolve().unlink(missing_ok=True)
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
