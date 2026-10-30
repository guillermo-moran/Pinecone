"""Add untimed-only diagnostic counters to a disposable prepared source tree."""
import re
from pathlib import Path
import stat


def instrument(snapshot: Path):
    repository = Path(__file__).resolve().parents[2]
    if snapshot.is_symlink():
        raise ValueError('symlink snapshot')
    snapshot = snapshot.resolve(strict=True)
    if snapshot == repository or repository in snapshot.parents or snapshot in repository.parents:
        raise ValueError('snapshot must be external to repository')
    def regular(relative):
        p = snapshot
        for component in Path(relative).parts:
            p = p / component
            if p.is_symlink():
                raise ValueError(f'symlink forbidden: {p}')
        s = p.stat()
        if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
            raise ValueError(f'not an independent regular file: {p}')
        return p
    regular('.pinecone-phase1-snapshot')
    native = snapshot / 'Sources/ARM64VizNative'
    changes = []
    originals, staged = {}, {}

    def read(filename):
        path = regular('Sources/ARM64VizNative/' + filename)
        if filename not in originals:
            originals[filename] = path.read_text()
            staged[filename] = originals[filename]
        return staged[filename]

    def entry(filename, name, field, expected=1):
        source = read(filename)
        # Disabled-build stubs are not part of this instrumented translation unit.
        enabled_end = source.index('\n#else\n', source.index('AVZThreadedPrototype *avz_tp_create')) if name == 'avz_tp_create' else len(source)
        pattern = r'(?m)^[^\s#][^;\n{}]*\b' + re.escape(name) + r'\([^;{}]*\)\s*\{'
        matches = list(re.finditer(pattern, source[:enabled_end]))
        if len(matches) != expected:
            raise ValueError(f'{filename}: {name}: expected {expected} definitions, got {len(matches)}')
        for match in reversed(matches):
            i = match.end()
            source = source[:i] + f'\n    P1_COUNT({field});' + source[i:]
        staged[filename] = source
        changes.append({'file': filename, 'function': name, 'counter': field})

    entry('ARM64VizNative.c', 'avz_native_run_threaded_prototype_block', 'prototype_entries')
    entry('ARM64VizNative.c', 'avz_native_prepare_threaded_block', 'eligibility_lookups')
    entry('ARM64VizNative.c', 'avz_native_run_threaded_decoded_block_cpu_mapped_span', 'established_entries')
    entry('ARM64VizBlockCache.c', 'avz_native_block_cache_threaded_program_with_memory', 'program_lookups')
    entry('ARM64VizThreadedPrototype.c', 'avz_tp_create', 'program_creations')
    entry('ARM64VizThreadedPrototype.c', 'tp_is_current', 'validations')
    entry('ARM64VizGuestMemory.c', 'avz_native_fast_memory_read', 'full_reads')
    entry('ARM64VizGuestMemory.c', 'avz_native_fast_memory_write', 'full_writes')
    entry('ARM64VizGuestMemory.c', 'avz_native_fast_memory_commit_write_span', 'commit_calls')
    source = read('ARM64VizGuestMemoryInternal.h')
    for access in ('read', 'write'):
        needle = f'    if (fast_path->detailed_statistics_enabled) {{\n        fast_path->statistics.{access}_tlb_hits++;'
        if source.count(needle) != 1:
            raise ValueError(f'hot {access} counter insertion mismatch')
        source = source.replace(needle, f'    P1_COUNT(hot_{access}s);\n' + needle)
    staged['ARM64VizGuestMemoryInternal.h'] = source
    source = read('ARM64VizNative.c')
    needle = '        memory, cache, code_epoch, shared_epoch);\n'
    if source.count(needle) != 1:
        raise ValueError('independent result-ledger insertion mismatch')
    staged['ARM64VizNative.c'] = source.replace(needle, needle +
        '    P1_RECORD(requested_steps, limit, result.steps, result.status);\n')
    for filename, original in originals.items():
        if regular('Sources/ARM64VizNative/' + filename).read_text() != original:
            raise ValueError('source drift before ledger write')
    # All patterns and files are validated before the first write.
    for filename, source in staged.items():
        (native / filename).write_text(source)
    return changes
