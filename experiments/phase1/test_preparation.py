"""Focused owner-run rejection checks. No native execution or runtime edits."""
import json
from pathlib import Path
import shutil
import tempfile
import sys
import measure


def main():
    output = Path(sys.argv[1]).resolve()
    manifest = json.loads((output / 'manifest.json').read_text())
    frozen = Path(manifest['frozen'])
    records = []
    live = {str(p.relative_to(measure.ROOT)): measure.sha(p)
            for p in (measure.ROOT / 'Sources/ARM64VizNative').rglob('*') if p.is_file()}
    with tempfile.TemporaryDirectory(prefix='phase1-rejection.', dir='/private/tmp') as work:
        work = Path(work)
        for name, variant in [('prepare_boundaries', 'prototype-limit-16'),
                              ('prepare_cost_controls', 'cost-prototype-stats-off'),
                              ('instrument_ledger', None)]:
            module = measure.load_module(name)
            def apply(root):
                return module.instrument(root) if variant is None else module.prepare(root, variant)
            for scenario in ['real-root', 'missing-marker', 'source-drift', 'symlink', 'hardlink']:
                root = work / (name + '-' + scenario)
                shutil.copytree(frozen, root)
                target = root / 'Sources/ARM64VizNative/ARM64VizNative.c'
                if scenario == 'real-root':
                    root = measure.ROOT
                elif scenario == 'missing-marker':
                    (root / '.pinecone-phase1-snapshot').unlink()
                elif scenario == 'source-drift':
                    target.write_text('/* unexpected source */\n')
                elif scenario == 'symlink':
                    target.unlink(); target.symlink_to(frozen / target.relative_to(root))
                else:
                    target.unlink(); target.hardlink_to(frozen / target.relative_to(root))
                before = measure.hashes(root) if scenario != 'real-root' else None
                try:
                    apply(root)
                except (ValueError, FileNotFoundError) as e:
                    records.append({'module': name, 'scenario': scenario, 'rejected': str(e)})
                else:
                    raise AssertionError((name, scenario, 'unexpected acceptance'))
                if before is not None:
                    assert before == measure.hashes(root), 'rejection changed snapshot'
                if scenario == 'hardlink':
                    target.unlink()
    assert live == {str(p.relative_to(measure.ROOT)): measure.sha(p)
                   for p in (measure.ROOT / 'Sources/ARM64VizNative').rglob('*') if p.is_file()}
    measure.write_json(output / 'preparation-rejections.json', {'passed': len(records), 'records': records,
                       'runtime_hashes_unchanged': True})
    print('PASS', len(records), 'snapshot rejection cases; live native hashes unchanged')
    source = output / 'test_ledger.c'
    measure.copy_file(measure.HERE / 'test_ledger.c', source)
    binary = Path(manifest['work']) / 'test-ledger-status'
    command = ['clang', '-std=c11', '-O3', '-DP1_LEDGER=1',
               '-I', frozen / 'experiments/phase1',
               '-I', frozen / 'Sources/ARM64VizNative/include', source, '-o', binary]
    build = measure.invoke(command)
    measure.write_json(output / 'test-ledger-build.json', build)
    assert build['returncode'] == 0, build
    test = measure.invoke([binary])
    measure.write_json(output / 'test-ledger-status.json', {**test, 'binary_sha256': measure.sha(binary),
                       'source_sha256': measure.sha(source),
                       'header_sha256': measure.sha(frozen / 'experiments/phase1/ledger.h')})
    assert test['returncode'] == 0, test
    print(test['stdout'].strip())


if __name__ == '__main__':
    main()
