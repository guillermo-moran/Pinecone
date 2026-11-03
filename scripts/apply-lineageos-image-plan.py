#!/usr/bin/env python3
"""Validate or apply a narrowly allowlisted LineageOS image patch plan.

The default is a dry run.  --apply requires a new output path, uses an APFS
copy-on-write clone, and never writes to the source image.
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
from typing import Any


class PlanError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, accepted: tuple[int, ...] = (0,)) -> subprocess.CompletedProcess:
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode not in accepted:
        detail = result.stderr.strip() or result.stdout.strip()
        raise PlanError(f"command failed ({result.returncode}): {' '.join(command)}\n{detail}")
    return result


def find_tool(environment_name: str, candidates: list[str]) -> str:
    configured = os.environ.get(environment_name)
    if configured:
        if not Path(configured).is_file() and shutil.which(configured) is None:
            raise PlanError(f"{environment_name} does not name an executable: {configured}")
        return configured
    for candidate in candidates:
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
        if Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise PlanError(
        f"missing required tool {candidates[0]}; set {environment_name} to its path"
    )


def load_plan(path: Path) -> dict[str, Any]:
    try:
        plan = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PlanError(f"cannot read plan {path}: {error}") from error
    if plan.get("schemaVersion") != 1:
        raise PlanError("unsupported image-plan schema")
    actions = plan.get("actions")
    if not isinstance(actions, list) or not actions:
        raise PlanError("plan must contain at least one action")
    for action in actions:
        if action.get("type") != "replaceFile":
            raise PlanError(f"unsupported action type: {action.get('type')}")
        required = {
            "partition",
            "path",
            "replacement",
            "existingSha256",
            "replacementSha256",
            "selinuxContext",
        }
        missing = sorted(required - action.keys())
        if missing:
            raise PlanError(f"action is missing fields: {', '.join(missing)}")
    return plan


def inspect_image(inspector: Path, image: Path) -> dict[str, Any]:
    result = run([sys.executable, str(inspector), str(image), "--json"])
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise PlanError("image inspector returned invalid JSON") from error


def partition_map(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {part["name"]: part for part in report["super"]["partitions"]}


def extract_partition(
    inspector: Path, image: Path, partition: str, output_dir: Path
) -> Path:
    run(
        [
            sys.executable,
            str(inspector),
            str(image),
            "--extract",
            partition,
            "--output-dir",
            str(output_dir),
        ]
    )
    return output_dir / f"{partition}.img"


def verify_action_inputs(
    action: dict[str, Any], plan_dir: Path, debugfs: str, partition_image: Path, work: Path
) -> Path:
    replacement = (plan_dir / action["replacement"]).resolve()
    if not replacement.is_file():
        raise PlanError(f"replacement does not exist: {replacement}")
    actual_replacement = sha256(replacement)
    if actual_replacement != action["replacementSha256"]:
        raise PlanError(
            f"replacement checksum mismatch for {replacement}: {actual_replacement}"
        )

    existing = work / "existing-file"
    run([debugfs, "-R", f"dump -p {action['path']} {existing}", str(partition_image)])
    actual_existing = sha256(existing)
    if actual_existing != action["existingSha256"]:
        raise PlanError(
            f"existing checksum mismatch for {action['partition']}:{action['path']}: "
            f"{actual_existing}"
        )
    return replacement


def apply_action(
    action: dict[str, Any], replacement: Path, debugfs: str, partition_image: Path, work: Path
) -> None:
    run([debugfs, "-w", "-R", f"rm {action['path']}", str(partition_image)])
    run(
        [
            debugfs,
            "-w",
            "-R",
            f"write {replacement} {action['path']}",
            str(partition_image),
        ]
    )
    context = work / "selinux-context"
    context.write_bytes(action["selinuxContext"].encode("utf-8") + b"\0")
    run(
        [
            debugfs,
            "-w",
            "-R",
            f"ea_set -f {context} -r {action['path']} security.selinux",
            str(partition_image),
        ]
    )
    result = work / "replacement-check"
    run([debugfs, "-R", f"dump -p {action['path']} {result}", str(partition_image)])
    if sha256(result) != action["replacementSha256"]:
        raise PlanError(f"post-write verification failed for {action['path']}")


def write_partition(
    output: Path, report: dict[str, Any], partition: dict[str, Any], image: Path
) -> None:
    extents = partition["extents"]
    if len(extents) != 1:
        raise PlanError(f"refusing to write multi-extent partition {partition['name']}")
    extent = extents[0]
    if extent["targetType"] != 0 or extent["targetSource"] != 0:
        raise PlanError(f"refusing to write non-linear partition {partition['name']}")
    expected_size = extent["numSectors"] * 512
    if image.stat().st_size != expected_size:
        raise PlanError(
            f"partition image size changed for {partition['name']}: "
            f"expected {expected_size}, got {image.stat().st_size}"
        )
    offset = (report["super"]["firstLBA"] + extent["targetData"]) * 512
    with output.open("r+b") as target, image.open("rb") as source:
        target.seek(offset)
        while chunk := source.read(8 * 1024 * 1024):
            target.write(chunk)
        target.flush()
        os.fsync(target.fileno())


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="unmodified pinned vda.raw")
    parser.add_argument(
        "--plan", type=Path, default=script_dir / "lineageos-image-plan.json"
    )
    parser.add_argument("--apply", action="store_true", help="create the patched output")
    parser.add_argument("--output", type=Path, help="new raw disk path for --apply")
    args = parser.parse_args()

    output_created = False
    try:
        source = args.source.resolve()
        plan_path = args.plan.resolve()
        if not source.is_file():
            raise PlanError(f"source does not exist: {source}")
        if args.apply != bool(args.output):
            raise PlanError("--apply and --output must be used together")
        output = args.output.resolve() if args.output else None
        if output and output.exists():
            raise PlanError(f"refusing to overwrite existing output: {output}")
        if output and output == source:
            raise PlanError("source and output must be different paths")

        plan = load_plan(plan_path)
        expected_size = plan["source"]["sizeBytes"]
        if source.stat().st_size != expected_size:
            raise PlanError(
                f"source size mismatch: expected {expected_size}, got {source.stat().st_size}"
            )
        print(f"verifying source SHA-256 ({expected_size} bytes)...", file=sys.stderr)
        actual_source_hash = sha256(source)
        if actual_source_hash != plan["source"]["sha256"]:
            raise PlanError(
                f"source checksum mismatch: expected {plan['source']['sha256']}, "
                f"got {actual_source_hash}"
            )

        inspector = script_dir / "inspect-lineageos-image.py"
        report = inspect_image(inspector, source)
        partitions = partition_map(report)
        debugfs = find_tool(
            "LINEAGE_DEBUGFS",
            ["debugfs", "/opt/homebrew/opt/e2fsprogs/sbin/debugfs"],
        )
        e2fsck = None
        if args.apply:
            e2fsck = find_tool(
                "LINEAGE_E2FSCK",
                ["e2fsck", "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck"],
            )

        with tempfile.TemporaryDirectory(prefix="arm64viz-lineage-plan-") as temporary:
            work = Path(temporary)
            prepared: dict[str, Path] = {}
            replacements: list[tuple[dict[str, Any], Path]] = []
            for action in plan["actions"]:
                name = action["partition"]
                if name not in partitions:
                    raise PlanError(f"plan references missing partition: {name}")
                if name not in prepared:
                    partition_dir = work / name
                    partition_dir.mkdir()
                    prepared[name] = extract_partition(
                        inspector, source, name, partition_dir
                    )
                replacement = verify_action_inputs(
                    action, plan_path.parent, debugfs, prepared[name], work
                )
                replacements.append((action, replacement))
                print(
                    f"validated: {name}:{action['path']} <- {replacement.name}\n"
                    f"  {action.get('reason', '')}"
                )

            if not args.apply:
                print("dry run complete; source image was not modified")
                return 0

            assert output is not None and e2fsck is not None
            for action, replacement in replacements:
                apply_action(action, replacement, debugfs, prepared[action["partition"]], work)
            for name, image in prepared.items():
                run([e2fsck, "-fy", str(image)], accepted=(0, 1, 2))

            output.parent.mkdir(parents=True, exist_ok=True)
            run(["cp", "-c", str(source), str(output)])
            output_created = True
            for name, image in prepared.items():
                write_partition(output, report, partitions[name], image)

            provenance = output.with_name(output.name + ".provenance.json")
            if provenance.exists():
                raise PlanError(f"refusing to overwrite provenance file: {provenance}")
            record = {
                "schemaVersion": 1,
                "source": str(source),
                "sourceSha256": actual_source_hash,
                "plan": str(plan_path),
                "planSha256": sha256(plan_path),
                "output": str(output),
                "actions": plan["actions"],
            }
            provenance.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
            print(f"created copy-on-write disk: {output}")
            print(f"wrote provenance: {provenance}")
    except (PlanError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        if output_created and args.output:
            Path(args.output).resolve().unlink(missing_ok=True)
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
