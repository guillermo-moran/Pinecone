"""Prepare nonproduction, fixed-invocation Phase 1 controls; never run them."""

from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile


_REPOSITORY = Path("/Users/gmoran/Documents/Projects/arm64viz")
_MARKER = ".pinecone-phase1-snapshot"
_RECORD = ".pinecone-phase1-cost-controls-preparation.json"
_NATIVE = "Sources/ARM64VizNative/ARM64VizNative.c"
_TP = "Sources/ARM64VizNative/ARM64VizThreadedPrototype.c"
_HASHES = {
    _NATIVE: "a1f6ca7ce718bbc7eb271ca3153d935b671d8e7bb502960982020466f108269f",
    _TP: "5fd3ae108b6f860d698e3a7998743eb72f2725b75f7d8ed87678905fb3b07416",
    "Sources/ARM64VizNative/ARM64VizBlockCache.c":
        "5153bd7b2c98007d0c80b10de11a45eb87a48e797f204025a5ed92b82e591992",
    "Sources/ARM64VizNative/ARM64VizGuestMemory.c":
        "d2233c3b054b0cbffcd28e36ceb46451a2424ed4b3db590f2be1841994649266",
    "Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h":
        "ae1d82fd71356eb0ff270d50e3daa5a886eecaeb863322a6eaa1735a3832acb9",
    "Sources/ARM64VizNative/include/ARM64VizThreadedPrototype.h":
        "94758ebdf1db44d4c97ae23b4973abd90ae6a0a92a5e7bd8a01f6b4b2ad1934a",
    "scripts/threaded-runtime-regression.c":
        "79545f80af49ce93c60fa231c049fd0b9b714afbcca1f88bdbf87c3f6a5fee41",
}
_MODES = ["--dispatch-benchmark", "--benchmark"]
_SAFETY = [
    "Disposable marked copy only; never the app, runtime checkout, or a general test suite.",
    "Single executing thread; immutable guest code and translations; no external writers.",
    "No invalidation, reentrant reclamation, devices, observers, or shared guest-memory object.",
    "Original decoded-block-count invocation cap and checkpoint/step budgets remain fixed.",
    "Use only the declared arithmetic or raw-RAM memory loop; no production correctness claim.",
    "Hypatia owns preparation/warmness, assertions, ledger, compilation and serial execution.",
    "Maxwell must approve exact tooling/fixture hashes before timing; preparation is not approval.",
]
_VARIANTS = [
    {
        "id": "cost-reference",
        "description": "Unmodified source reference at the existing invocation policy.",
        "hypothesis": "Establish the matched control with every validation and statistic retained.",
        "changed_factors": [],
        "matched_control": None,
        "allowed_modes": _MODES,
        "detailed_memory_statistics": 1,
    },
    {
        "id": "cost-validation-entry-only",
        "description": "Omit only TP_NEXT post-instruction currency validation; retain guarded entry and pinning.",
        "hypothesis": "Post-instruction validation contributes measurable cost even with fixed invocation frequency.",
        "changed_factors": ["prototype.post_instruction_currency_validation: enabled -> omitted"],
        "matched_control": "cost-reference",
        "allowed_modes": _MODES,
        "detailed_memory_statistics": 1,
    },
    {
        "id": "cost-prototype-stats-off",
        "description": "Omit only the two unconditional wrapper block/step statistics atomic fetch-adds.",
        "hypothesis": "Per-invocation block/step statistics contribute cost separately from validation.",
        "changed_factors": ["prototype.wrapper_block_and_step_statistics: enabled -> omitted"],
        "matched_control": "cost-reference",
        "allowed_modes": _MODES,
        "detailed_memory_statistics": 1,
    },
    {
        "id": "cost-memory-stats-on",
        "description": "Explicit detailed-memory-statistics-on reference for the runner's raw-RAM fixture.",
        "hypothesis": "Provide the matched on arm for detailed-memory-statistics attribution.",
        "changed_factors": [],
        "matched_control": "cost-reference",
        "allowed_modes": ["--benchmark"],
        "detailed_memory_statistics": 1,
    },
    {
        "id": "cost-memory-stats-off",
        "description": "Disable detailed memory statistics through the runner's existing setup setter only.",
        "hypothesis": "Detailed-memory-statistics updates contribute common or differential memory-loop cost.",
        "changed_factors": ["memory.detailed_statistics_enabled: 1 -> 0 (fixture setup only)"],
        "matched_control": "cost-memory-stats-on",
        "allowed_modes": ["--benchmark"],
        "detailed_memory_statistics": 0,
    },
]

_POST_VALIDATION = r"""    if (!tp_is_current(execution)) { \
        execution->result.status = AVZ_TP_STATUS_REVALIDATE; \
        return; \
    } \
"""
_WRAPPER_STATISTICS = """    atomic_fetch_add_explicit(&context->threaded_prototype_blocks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&context->threaded_prototype_steps, result.steps, memory_order_relaxed);
"""
_INVOCATION_CAP = """    uint64_t limit = avz_native_decoded_block_instruction_count(block);
    if (limit > requested_steps) limit = requested_steps;
    AVZNativeBlockResult result = avz_tp_run_guarded(program, limit, &context->cpu,
        memory, cache, code_epoch, shared_epoch);
"""
_OFFLINE_GATE = """/* Phase 1 offline cost control. Not a runtime implementation. */
#if !defined(AVZ_PHASE1_OFFLINE_COST_CONTROL) || AVZ_PHASE1_OFFLINE_COST_CONTROL != 1
#error "Phase 1 cost control requires explicit offline fixture opt-in"
#endif

"""


def variants():
    """Return independent JSON-serializable descriptions; no filesystem access."""
    result = deepcopy(_VARIANTS)
    for variant in result:
        variant["safety_limits"] = list(_SAFETY)
        variant["invocation_policy"] = "decoded-block-count"
        variant["required_compile_defines"] = ["AVZ_PHASE1_OFFLINE_COST_CONTROL=1"]
        variant["review_required"] = True
    return result


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _snapshot_root(snapshot):
    candidate = Path(snapshot)
    if not candidate.is_absolute() or candidate.is_symlink():
        raise ValueError("Snapshot must be an absolute directory, not a symlink")
    root = candidate.resolve(strict=True)
    repository = _REPOSITORY.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("Snapshot root is not a directory")
    if root == repository or repository in root.parents or root in repository.parents:
        raise ValueError("Refusing repository, its descendants, or an enclosing directory")
    for parent in (root, *root.parents):
        if (parent / ".git").exists() or (parent / ".git").is_symlink():
            raise ValueError("Snapshot must not be inside a Git checkout/worktree")
    return root


def _regular_file(root, relative):
    path = root
    parts = Path(relative).parts
    if Path(relative).is_absolute() or ".." in parts:
        raise ValueError("Invalid snapshot-relative path")
    for index, part in enumerate(parts):
        path = path / part
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f"Symlink in snapshot path: {relative}")
        if index < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
            raise ValueError(f"Non-directory snapshot path component: {relative}")
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError(f"Expected an unshared regular file: {relative}")
    if not path.resolve(strict=True).is_relative_to(root):
        raise ValueError(f"Path escapes snapshot: {relative}")
    original = _REPOSITORY / relative
    if original.exists() and path.samefile(original):
        raise ValueError(f"Snapshot aliases repository file: {relative}")
    return path


def _unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate marker JSON key: {key}")
        result[key] = value
    return result


def _declaration(root, variant):
    marker = _regular_file(root, _MARKER)
    declaration = json.loads(marker.read_text(encoding="utf-8"), object_pairs_hook=_unique_json_object)
    if not isinstance(declaration, dict):
        raise ValueError("Marker must be a JSON object")
    limits = declaration.get("cost_controls")
    if not isinstance(limits, dict):
        raise ValueError("Missing cost_controls safety declaration")
    for key in ("single_thread", "immutable_guest_code", "no_external_writers", "no_invalidation"):
        if limits.get(key) is not True:
            raise ValueError(f"cost_controls.{key} must be JSON true")
    if limits.get("fixture") != "threaded-runtime-regression-benchmarks-v1":
        raise ValueError("Unsupported fixture declaration")
    if limits.get("invocation_policy") != "decoded-block-count":
        raise ValueError("Cost controls require unchanged decoded-block-count invocation policy")
    modes = limits.get("allowed_modes")
    if (not isinstance(modes, list) or not modes
            or any(not isinstance(mode, str) or mode not in _MODES for mode in modes)
            or len(set(modes)) != len(modes)):
        raise ValueError("allowed_modes must be a nonempty unique subset of the two benchmark modes")
    allowed = [mode for mode in variant["allowed_modes"] if mode in modes]
    if not allowed:
        raise ValueError("Variant has no mode permitted by the fixture declaration")
    return limits, allowed


def _require_once(source, pattern, label):
    count = source.count(pattern)
    if count != 1:
        raise ValueError(f"Expected exactly one {label}; found {count}")


def _replace_regular(root, relative, before, after):
    """Atomic file replacement; a failed preparation remains marked unusable."""
    target = _regular_file(root, relative)
    if target.read_bytes() != before:
        raise ValueError(f"Snapshot changed during preparation: {relative}")
    fd, temporary = tempfile.mkstemp(prefix=".phase1-cost-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), stat.S_IMODE(target.stat().st_mode))
            output.write(after)
            output.flush()
            os.fsync(output.fileno())
        if _regular_file(root, relative).read_bytes() != before:
            raise ValueError(f"Snapshot changed before replacement: {relative}")
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prepare(snapshot, variant):
    """Prepare one fresh snapshot and return its mandatory runner configuration.

    No compilation or execution occurs. Marker attestations are runner promises,
    not proof of fixture safety. Any failed/partial snapshot must be discarded.
    """
    advertised = {item["id"]: item for item in variants()}
    if not isinstance(variant, str) or variant not in advertised:
        raise ValueError("Unknown cost-control variant ID")
    selected = advertised[variant]
    root = _snapshot_root(snapshot)
    if (root / _RECORD).exists() or (root / _RECORD).is_symlink():
        raise ValueError("Snapshot already prepared or partially prepared; create a fresh copy")
    declaration, allowed_modes = _declaration(root, selected)
    sources = {}
    for relative, expected in _HASHES.items():
        data = _regular_file(root, relative).read_bytes()
        if _digest(data) != expected:
            raise ValueError(f"Frozen source hash mismatch: {relative}")
        sources[relative] = data

    native = sources[_NATIVE].decode("utf-8")
    prototype = sources[_TP].decode("utf-8")
    _require_once(native, _INVOCATION_CAP, "unchanged invocation cap")
    _require_once(native, _WRAPPER_STATISTICS, "wrapper block/step statistics pair")
    _require_once(prototype, _POST_VALIDATION, "post-instruction validation block")
    _require_once(prototype, "if (!tp_is_current(&execution)) {", "guarded entry validation")
    _require_once(prototype, "pinned->active_runs++;", "entry pin")
    _require_once(prototype, "if (--pinned->active_runs == 0 && pinned->retired) free(pinned);", "exit unpin")

    edits = {}
    if variant == "cost-validation-entry-only":
        edits[_TP] = (_OFFLINE_GATE + prototype.replace(_POST_VALIDATION, "", 1)).encode("utf-8")
    elif variant == "cost-prototype-stats-off":
        edits[_NATIVE] = (_OFFLINE_GATE + native.replace(_WRAPPER_STATISTICS, "", 1)).encode("utf-8")

    summary = {
        **selected,
        "snapshot": str(root),
        "allowed_modes": allowed_modes,
        "safety_declaration": declaration,
        "preparation_record": _RECORD,
        "source_hashes_before": dict(_HASHES),
        "source_hashes_after": {
            relative: _digest(edits.get(relative, data)) for relative, data in sources.items()
        },
        "changed_files": sorted(edits),
        "common_scaffolding": "Modified C files require explicit offline compile opt-in; no runtime guard added.",
        "runner_requirements": [
            "Apply required_compile_defines identically to all matched cost arms.",
            "Set detailed_memory_statistics via existing setter on the ACTUAL memory fixture outside timing.",
            "Use exactly one variant per fresh snapshot; do not combine with boundary controls.",
            "Prepare before runner ledger instrumentation; retain independent pristine timing copy.",
            "Retain fixed invocation/checkpoint policies, guest PC/steps/budget and expected-state assertions.",
            "Verify work with independent untimed ledger, not disabled prototype or memory counters.",
            "Keep cold/prewarmed execution separate; preparation does not create or reset fixtures.",
            "Retain exact diffs/hashes and obtain Maxwell review before timing; never deploy.",
        ],
    }
    # Exclusive claim makes metadata-only arms and interrupted edits non-reusable.
    pending = json.dumps({"state": "preparing", "variant": variant}, sort_keys=True).encode("utf-8") + b"\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(root / _RECORD, flags, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(pending)
        output.flush()
        os.fsync(output.fileno())
    for relative, after in edits.items():
        _replace_regular(root, relative, sources[relative], after)
    for relative, expected in summary["source_hashes_after"].items():
        if _digest(_regular_file(root, relative).read_bytes()) != expected:
            raise ValueError(f"Post-preparation verification failed: {relative}; discard snapshot")
    summary["state"] = "prepared-awaiting-review"
    completed = json.dumps(summary, sort_keys=True, indent=2).encode("utf-8") + b"\n"
    _replace_regular(root, _RECORD, pending, completed)
    return summary
