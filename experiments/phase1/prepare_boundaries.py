"""Prepare isolated Phase 1 boundary controls; never compile or execute them.

Import from the live tooling directory and call prepare on a fresh copied
snapshot, before ledger instrumentation. See boundaries.md for fixture limits.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import tempfile


_REPOSITORY = Path("/Users/gmoran/Documents/Projects/arm64viz")
_MARKER = ".pinecone-phase1-snapshot"
_NATIVE = "Sources/ARM64VizNative/ARM64VizNative.c"
_LIMITS = (4, 16, 64, 256, 4096)
_EXPECTED_SHA256 = {
    _NATIVE: "a1f6ca7ce718bbc7eb271ca3153d935b671d8e7bb502960982020466f108269f",
    "Sources/ARM64VizNative/ARM64VizThreadedPrototype.c":
        "5fd3ae108b6f860d698e3a7998743eb72f2725b75f7d8ed87678905fb3b07416",
    "Sources/ARM64VizNative/ARM64VizBlockCache.c":
        "5153bd7b2c98007d0c80b10de11a45eb87a48e797f204025a5ed92b82e591992",
    "Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h":
        "ae1d82fd71356eb0ff270d50e3daa5a886eecaeb863322a6eaa1735a3832acb9",
    "Sources/ARM64VizNative/include/ARM64VizNative.h":
        "c6455e5d203cd1f84e0d31a999dfda66a7b402b5c82799b421de079b2c702de7",
    "Sources/ARM64VizNative/include/ARM64VizThreadedPrototype.h":
        "94758ebdf1db44d4c97ae23b4973abd90ae6a0a92a5e7bd8a01f6b4b2ad1934a",
}

_LIMIT_BEFORE = """    /* At most one block's worth of instructions, including backward branches.
     * Re-enter the existing cache validation/timer/checkpoint path afterwards.
     * Pure arithmetic cannot invoke callbacks or invalidate its own snapshot. */
    uint64_t limit = avz_native_decoded_block_instruction_count(block);
    if (limit > requested_steps) limit = requested_steps;
    AVZNativeBlockResult result = avz_tp_run_guarded(program, limit, &context->cpu,
        memory, cache, code_epoch, shared_epoch);
"""

_LOOKUP_BEFORE = """        active_superblock = avz_native_find_superblock(
            context,
            cache,
            &key,
            &superblock_front_hit
        );
"""

_COMPOSE_BEFORE = """        if (active_superblock == NULL
#if AVZ_THREADED_PROTOTYPE_ENABLE
            && !threaded_eligible
#endif
        ) {
            uint64_t block_serial =
                avz_native_decoded_block_serial(cache, block);
            const AVZNativeSuperblock *composed =
                avz_native_compose_superblock(
                    context,
                    cache,
                    &key,
                    block,
                    block_serial
                );
            if (composed != NULL) {
                active_superblock = composed;
            }
        }
"""


def variants() -> list[dict]:
    """Return independent arms; runtime executor selection belongs to runner."""
    common = [
        "Disposable copied snapshot only; never an app or installed binary.",
        "Immutable four-instruction self-loop fixtures; one execution thread.",
        "No devices, guest IRQ deadlines, observers, concurrent mutation or reclamation.",
        "Use checkpointed API with requested/checkpoint budget at most 4096.",
        "Review plus owner-run prefix/full-state/RAM checks required before timing.",
    ]
    result = []
    for limit in _LIMITS:
        result.append({
            "id": f"prototype-limit-{limit}",
            "description": (
                f"Cap four-instruction prototype blocks at min({limit}, requested_steps); "
                "other decoded block lengths retain their original cap."
            ),
            "hypothesis": (
                "Repeated invocation/chain work contributes to the integrated regression; "
                "widening the cap reduces its frequency with validation/statistics retained."
            ),
            "safety_limits": list(common),
            "changed_factors": [
                "Four-instruction prototype invocation cap only; decoded-count getter retained.",
                "Consequent entry, lookup, statistics-update and outer-accounting frequencies.",
                "Per-instruction validation, CPU/step updates and requested-step clamp unchanged.",
            ],
            "required_executor": "prototype",
            "invocation_limit": limit,
            "eligible_decoded_count": 4,
            "matched_control": "prototype-limit-4 and unchanged prototype baseline",
        })
    result.append({
        "id": "established-superblock-off",
        "description": "Disable cached superblock lookup and new composition in checkpointed chain.",
        "hypothesis": "Established superblock policy contributes separately to the executor gap.",
        "safety_limits": list(common) + [
            "Prototype and threaded-memory runtime selections must both be disabled.",
            "Do not combine with any invocation-limit or cost-control transformation.",
        ],
        "changed_factors": [
            "Cached superblock lookup and new composition bypassed together.",
            "Mapped-trace execution, associated metadata/work and entry frequencies consequently change.",
            "Direct links, ordinary decoded-block selection and established semantic handlers retained.",
            "Prototype invocation policy untouched; not a dispatch-only comparison.",
        ],
        "required_executor": "established",
        "matched_control": "unchanged established baseline",
    })
    return result


def _regular_file(root: Path, relative: str) -> Path:
    path = root
    for component in Path(relative).parts:
        path = path / component
        if path.is_symlink():
            raise ValueError(f"Snapshot symlink forbidden: {path}")
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError(f"Expected regular, non-hardlinked snapshot file: {path}")
    if root not in path.resolve(strict=True).parents:
        raise ValueError(f"Snapshot path escapes root: {path}")
    return path


def _snapshot_root(snapshot: Path) -> Path:
    supplied = Path(snapshot)
    if supplied.is_symlink():
        raise ValueError("Snapshot root itself cannot be a symlink")
    root = supplied.resolve(strict=True)
    repository = _REPOSITORY.resolve(strict=True)
    if root == repository or repository in root.parents or root in repository.parents:
        raise ValueError("Snapshot must be outside the real repository and its ancestors")
    if not root.is_dir() or (root / ".git").exists() or (root / ".git").is_symlink():
        raise ValueError("Expected disposable source directory, not a Git checkout")
    _regular_file(root, _MARKER)
    return root


def _read_fixture(root: Path) -> dict[str, bytes]:
    content = {}
    for relative, expected in _EXPECTED_SHA256.items():
        data = _regular_file(root, relative).read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != expected:
            raise ValueError(f"Unexpected fixture source {relative}: {actual}; expected {expected}")
        content[relative] = data
    return content


def prepare(snapshot: Path, variant: str) -> dict:
    """Apply one bounded transformation or fail before replacing any source.

    Source fixtures are pinned deliberately. Do not refresh hashes merely to
    bypass drift: an updated fixture/module requires independent re-review.
    Caller owns a quiescent snapshot; this is not a concurrent writer protocol.
    """
    available = {item["id"]: item for item in variants()}
    if variant not in available:
        raise ValueError(f"Unknown boundary variant: {variant!r}")
    root = _snapshot_root(snapshot)
    before = _read_fixture(root)
    source = before[_NATIVE].decode("utf-8")
    edits = []
    if variant == "established-superblock-off":
        edits = [
            (_LOOKUP_BEFORE,
             "        /* PHASE1_BOUNDARY: offline established superblock lookup disabled. */\n"
             "        active_superblock = NULL;\n"),
            (_COMPOSE_BEFORE,
             "        /* PHASE1_BOUNDARY: offline established superblock composition disabled. */\n"),
        ]
    else:
        limit = available[variant]["invocation_limit"]
        edits = [(_LIMIT_BEFORE,
            "    /* PHASE1_BOUNDARY: immutable offline four-instruction loop only.\n"
            "     * Preserve all guards and the caller's checkpoint/step deadline. */\n"
            "    uint64_t limit = avz_native_decoded_block_instruction_count(block);\n"
            f"    if (limit == 4) limit = UINT64_C({limit});\n"
            "    if (limit > requested_steps) limit = requested_steps;\n"
            "    AVZNativeBlockResult result = avz_tp_run_guarded(program, limit, &context->cpu,\n"
            "        memory, cache, code_epoch, shared_epoch);\n"
        )]
    # Check all replacements against the original before constructing output.
    for old, _ in edits:
        matches = source.count(old)
        if matches != 1:
            raise ValueError(f"Expected one source match, got {matches}: {old.splitlines()[0]}")
    modified = source
    changes = []
    for old, new in edits:
        changes.append({
            "source_line": source[:source.index(old)].count("\n") + 1,
            "matches": 1,
            "before": old,
            "after": new,
        })
        modified = modified.replace(old, new, 1)
    after = modified.encode("utf-8")
    target = _regular_file(root, _NATIVE)
    mode = stat.S_IMODE(target.stat().st_mode)
    fd, temporary = tempfile.mkstemp(prefix=".phase1-boundaries-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(after)
            output.flush()
            os.fsync(output.fileno())
        _snapshot_root(root)
        if _read_fixture(root) != before:
            raise ValueError("Snapshot changed during preparation")
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {
        "variant": variant,
        "snapshot": str(root),
        "metadata": available[variant],
        "validated_sources_sha256": dict(_EXPECTED_SHA256),
        "changed_files": [{
            "path": _NATIVE,
            "sha256_before": hashlib.sha256(before[_NATIVE]).hexdigest(),
            "sha256_after": hashlib.sha256(after).hexdigest(),
            "replacements": changes,
        }],
        "compilation_or_execution": "none",
        "review_status": "not approved by preparation; independent review required",
    }
