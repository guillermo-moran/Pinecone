#!/usr/bin/env python3
"""Inspect and selectively extract Android dynamic partitions from a raw disk.

This tool is deliberately read-only.  It validates the GPT and liblp checksums
before reporting offsets, and extracted files are created exclusively so an
existing image is never replaced by accident.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import uuid
import zlib


SECTOR_SIZE = 512
GPT_SIGNATURE = b"EFI PART"
LP_GEOMETRY_MAGIC = 0x616C4467
LP_HEADER_MAGIC = 0x414C5030
LP_TARGET_TYPE_LINEAR = 0


class ImageError(RuntimeError):
    pass


def checked_read(handle, offset: int, size: int) -> bytes:
    handle.seek(offset)
    data = handle.read(size)
    if len(data) != size:
        raise ImageError(
            f"short read at byte {offset}: expected {size}, received {len(data)}"
        )
    return data


def verify_crc32(label: str, data: bytes, expected: int) -> None:
    actual = zlib.crc32(data) & 0xFFFFFFFF
    if actual != expected:
        raise ImageError(
            f"{label} CRC32 mismatch: expected {expected:08x}, got {actual:08x}"
        )


def verify_sha256(label: str, data: bytes, expected: bytes) -> None:
    actual = hashlib.sha256(data).digest()
    if actual != expected:
        raise ImageError(
            f"{label} SHA-256 mismatch: expected {expected.hex()}, got {actual.hex()}"
        )


def parse_gpt(handle) -> list[dict]:
    raw = checked_read(handle, SECTOR_SIZE, SECTOR_SIZE)
    values = struct.unpack_from("<8sIIIIQQQQ16sQIII", raw)
    (
        signature,
        _revision,
        header_size,
        header_crc,
        _reserved,
        _current_lba,
        _backup_lba,
        first_usable_lba,
        last_usable_lba,
        disk_guid,
        entries_lba,
        entry_count,
        entry_size,
        entries_crc,
    ) = values
    if signature != GPT_SIGNATURE:
        raise ImageError("disk does not contain a GPT header at LBA 1")
    if not 92 <= header_size <= SECTOR_SIZE:
        raise ImageError(f"invalid GPT header size {header_size}")
    if entry_size < 128 or entry_count > 4096:
        raise ImageError("unsupported GPT partition table dimensions")

    crc_header = bytearray(raw[:header_size])
    crc_header[16:20] = b"\0" * 4
    verify_crc32("GPT header", crc_header, header_crc)

    raw_entries = checked_read(
        handle, entries_lba * SECTOR_SIZE, entry_count * entry_size
    )
    verify_crc32("GPT partition table", raw_entries, entries_crc)

    partitions = []
    for index in range(entry_count):
        entry = raw_entries[index * entry_size : (index + 1) * entry_size]
        type_guid = entry[:16]
        if type_guid == b"\0" * 16:
            continue
        unique_guid = entry[16:32]
        first_lba, last_lba, attributes = struct.unpack_from("<QQQ", entry, 32)
        if first_lba < first_usable_lba or last_lba > last_usable_lba:
            raise ImageError(f"GPT partition {index + 1} lies outside usable LBAs")
        name = entry[56:128].decode("utf-16-le").rstrip("\0")
        partitions.append(
            {
                "index": index + 1,
                "name": name,
                "typeGUID": str(uuid.UUID(bytes_le=type_guid)),
                "uniqueGUID": str(uuid.UUID(bytes_le=unique_guid)),
                "firstLBA": first_lba,
                "lastLBA": last_lba,
                "sizeBytes": (last_lba - first_lba + 1) * SECTOR_SIZE,
                "attributes": attributes,
            }
        )
    if not partitions:
        raise ImageError("GPT contains no partitions")
    return partitions


def parse_geometry(handle, super_offset: int) -> dict:
    raw = checked_read(handle, super_offset + 4096, 4096)
    magic, struct_size = struct.unpack_from("<II", raw)
    if magic != LP_GEOMETRY_MAGIC or not 52 <= struct_size <= len(raw):
        raise ImageError("super partition has invalid liblp geometry")
    checksum = raw[8:40]
    checked = bytearray(raw[:struct_size])
    checked[8:40] = b"\0" * 32
    verify_sha256("liblp geometry", checked, checksum)
    metadata_max_size, metadata_slot_count, logical_block_size = struct.unpack_from(
        "<III", raw, 40
    )
    if metadata_max_size == 0 or metadata_slot_count == 0:
        raise ImageError("liblp geometry has no metadata slots")
    return {
        "metadataMaxSize": metadata_max_size,
        "metadataSlotCount": metadata_slot_count,
        "logicalBlockSize": logical_block_size,
    }


def descriptor(raw: bytes, offset: int) -> tuple[int, int, int]:
    table_offset, count, entry_size = struct.unpack_from("<III", raw, offset)
    if entry_size == 0 and count != 0:
        raise ImageError("liblp table has a zero-sized entry")
    return table_offset, count, entry_size


def c_string(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("utf-8", errors="strict")


def parse_metadata(handle, super_offset: int, geometry: dict) -> dict:
    # Reserved block + primary geometry + backup geometry precede slot 0.
    metadata_offset = super_offset + 3 * 4096
    raw_header = checked_read(handle, metadata_offset, 256)
    magic, major, minor, header_size = struct.unpack_from("<IHHI", raw_header)
    if magic != LP_HEADER_MAGIC or not 128 <= header_size <= len(raw_header):
        raise ImageError("super partition has invalid liblp slot-0 metadata")
    header = bytearray(raw_header[:header_size])
    header_checksum = bytes(header[12:44])
    header[12:44] = b"\0" * 32
    verify_sha256("liblp metadata header", header, header_checksum)

    tables_size = struct.unpack_from("<I", raw_header, 44)[0]
    if tables_size > geometry["metadataMaxSize"] - header_size:
        raise ImageError("liblp tables exceed the declared metadata slot size")
    tables_checksum = raw_header[48:80]
    tables = checked_read(handle, metadata_offset + header_size, tables_size)
    verify_sha256("liblp metadata tables", tables, tables_checksum)

    part_desc = descriptor(raw_header, 80)
    extent_desc = descriptor(raw_header, 92)
    group_desc = descriptor(raw_header, 104)
    device_desc = descriptor(raw_header, 116)

    def entries(desc):
        offset, count, entry_size = desc
        end = offset + count * entry_size
        if end > len(tables):
            raise ImageError("liblp table descriptor exceeds tables payload")
        return [
            tables[offset + i * entry_size : offset + (i + 1) * entry_size]
            for i in range(count)
        ]

    extents = []
    for entry in entries(extent_desc):
        if len(entry) < 24:
            raise ImageError("unsupported short liblp extent entry")
        num_sectors, target_type, target_data, target_source = struct.unpack_from(
            "<QIQI", entry
        )
        extents.append(
            {
                "numSectors": num_sectors,
                "targetType": target_type,
                "targetData": target_data,
                "targetSource": target_source,
            }
        )

    devices = []
    for entry in entries(device_desc):
        if len(entry) < 64:
            raise ImageError("unsupported short liblp block-device entry")
        first_sector, alignment, alignment_offset, size = struct.unpack_from(
            "<QIIQ", entry
        )
        devices.append(
            {
                "firstLogicalSector": first_sector,
                "alignment": alignment,
                "alignmentOffset": alignment_offset,
                "sizeBytes": size,
                "name": c_string(entry[24:60]),
                "flags": struct.unpack_from("<I", entry, 60)[0],
            }
        )

    groups = []
    for entry in entries(group_desc):
        if len(entry) < 48:
            raise ImageError("unsupported short liblp group entry")
        groups.append(
            {
                "name": c_string(entry[:36]),
                "flags": struct.unpack_from("<I", entry, 36)[0],
                "maximumSize": struct.unpack_from("<Q", entry, 40)[0],
            }
        )

    partitions = []
    for entry in entries(part_desc):
        if len(entry) < 52:
            raise ImageError("unsupported short liblp partition entry")
        attributes, first_extent, extent_count, group_index = struct.unpack_from(
            "<IIII", entry, 36
        )
        if first_extent + extent_count > len(extents) or group_index >= len(groups):
            raise ImageError("liblp partition references an invalid table index")
        partition_extents = extents[first_extent : first_extent + extent_count]
        size = sum(extent["numSectors"] * SECTOR_SIZE for extent in partition_extents)
        partitions.append(
            {
                "name": c_string(entry[:36]),
                "attributes": attributes,
                "group": groups[group_index]["name"],
                "sizeBytes": size,
                "extents": partition_extents,
            }
        )

    return {
        "metadataVersion": f"{major}.{minor}",
        "groups": groups,
        "blockDevices": devices,
        "partitions": partitions,
    }


def inspect_image(path: Path) -> dict:
    with path.open("rb") as handle:
        gpt = parse_gpt(handle)
        super_partitions = [part for part in gpt if part["name"] == "super"]
        if len(super_partitions) != 1:
            raise ImageError(
                f"expected exactly one GPT partition named super, found {len(super_partitions)}"
            )
        super_partition = super_partitions[0]
        super_offset = super_partition["firstLBA"] * SECTOR_SIZE
        geometry = parse_geometry(handle, super_offset)
        metadata = parse_metadata(handle, super_offset, geometry)
    return {
        "image": str(path),
        "imageSizeBytes": path.stat().st_size,
        "gptPartitions": gpt,
        "super": {
            "firstLBA": super_partition["firstLBA"],
            "sizeBytes": super_partition["sizeBytes"],
            **geometry,
            **metadata,
        },
    }


def copy_range(source, target, source_offset: int, size: int) -> None:
    source.seek(source_offset)
    remaining = size
    while remaining:
        chunk = source.read(min(8 * 1024 * 1024, remaining))
        if not chunk:
            raise ImageError("source image ended while extracting an extent")
        target.write(chunk)
        remaining -= len(chunk)


def extract_partitions(path: Path, report: dict, names: list[str], output_dir: Path) -> None:
    partitions = {part["name"]: part for part in report["super"]["partitions"]}
    unknown = sorted(set(names) - partitions.keys())
    if unknown:
        raise ImageError(f"unknown logical partition(s): {', '.join(unknown)}")
    output_dir.mkdir(parents=True, exist_ok=True)
    super_offset = report["super"]["firstLBA"] * SECTOR_SIZE
    with path.open("rb") as source:
        for name in names:
            partition = partitions[name]
            output_path = output_dir / f"{name}.img"
            try:
                target_fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError as error:
                raise ImageError(f"refusing to overwrite {output_path}") from error
            try:
                with os.fdopen(target_fd, "wb") as target:
                    for extent in partition["extents"]:
                        if extent["targetType"] != LP_TARGET_TYPE_LINEAR:
                            raise ImageError(
                                f"{name} contains unsupported non-linear extent type "
                                f"{extent['targetType']}"
                            )
                        if extent["targetSource"] != 0:
                            raise ImageError(
                                f"{name} references unsupported block device index "
                                f"{extent['targetSource']}"
                            )
                        copy_range(
                            source,
                            target,
                            super_offset + extent["targetData"] * SECTOR_SIZE,
                            extent["numSectors"] * SECTOR_SIZE,
                        )
            except BaseException:
                output_path.unlink(missing_ok=True)
                raise
            print(f"extracted {name} -> {output_path}", file=sys.stderr)


def human_report(report: dict) -> str:
    lines = [
        f"image: {report['image']}",
        f"image size: {report['imageSizeBytes']} bytes",
        "GPT partitions:",
    ]
    for part in report["gptPartitions"]:
        lines.append(
            f"  {part['index']:2d} {part['name']:<20} "
            f"LBA {part['firstLBA']}-{part['lastLBA']} ({part['sizeBytes']} bytes)"
        )
    super_report = report["super"]
    lines.extend(
        [
            f"liblp metadata version: {super_report['metadataVersion']}",
            f"liblp logical block size: {super_report['logicalBlockSize']}",
            "logical partitions:",
        ]
    )
    for part in super_report["partitions"]:
        extent_summary = ", ".join(
            f"sector {extent['targetData']}+{extent['numSectors']}"
            for extent in part["extents"]
        )
        lines.append(
            f"  {part['name']:<20} {part['sizeBytes']:>12} bytes  {extent_summary}"
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="raw GPT disk containing Android super")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument(
        "--extract",
        action="append",
        default=[],
        metavar="PARTITION",
        help="extract one logical partition (repeatable)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="directory for --extract output (required when extracting)",
    )
    args = parser.parse_args()
    try:
        if not args.image.is_file():
            raise ImageError(f"image does not exist: {args.image}")
        if bool(args.extract) != bool(args.output_dir):
            raise ImageError("--extract and --output-dir must be used together")
        report = inspect_image(args.image)
        if args.json:
            print(json.dumps(report, indent=2, sort_keys=True))
        else:
            print(human_report(report))
        if args.extract:
            extract_partitions(args.image, report, args.extract, args.output_dir)
    except (ImageError, OSError, UnicodeError, struct.error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
