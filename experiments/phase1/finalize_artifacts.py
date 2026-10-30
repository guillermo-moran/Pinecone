"""Retain disposable artifacts and confirm runtime source preservation after runs."""
import json
from pathlib import Path
import shutil
import sys
import tarfile
import measure


def main():
    output = Path(sys.argv[1]).resolve()
    manifest = json.loads((output / 'manifest.json').read_text())
    comparisons = {}
    for rel, expected in manifest['source_hashes'].items():
        if rel.startswith(('Sources/', 'scripts/')) or rel == 'Package.swift':
            comparisons[rel] = {'before': expected, 'after': measure.sha(measure.ROOT / rel)}
    assert all(x['before'] == x['after'] for x in comparisons.values())
    runtime_diff = measure.checked(['git', 'diff', '--', 'Sources', 'scripts', 'Apps'], cwd=measure.ROOT)
    assert runtime_diff == manifest['git_diff'], 'dirty runtime diff changed'
    measure.write_json(output / 'runtime-preservation.json', {'unchanged': True,
                       'dirty_runtime_diff_unchanged': True, 'files': comparisons})
    tooling = output / 'tooling'
    tooling.mkdir(exist_ok=True)
    for p in measure.HERE.iterdir():
        if p.is_file() and p.suffix in ['.py', '.c', '.h', '.md']:
            shutil.copyfile(p, tooling / p.name)
    assembly = output / 'assembly'
    assembly.mkdir(exist_ok=True)
    for id_ in ['baseline', 'prototype-limit-4096', 'cost-validation-entry-only', 'cost-prototype-stats-off']:
        arm = json.loads((output / id_ / 'arm.json').read_text())
        tree = Path(arm['timing_tree'])
        n = tree / 'Sources/ARM64VizNative'
        for name, source in [('fixture', tree / 'experiments/phase1/fixture.c'),
                             ('prototype', n / 'ARM64VizThreadedPrototype.c')]:
            target = assembly / (id_ + '-' + name + '.s')
            cmd = [shutil.which('clang'), *measure.FLAGS, '-include', tree / 'experiments/phase1/ledger.h',
                   '-I', n / 'include', '-I', n, '-S', source, '-o', target]
            result = measure.invoke(cmd)
            measure.write_json(target.with_suffix('.build.json'), result)
            assert result['returncode'] == 0, result
    work = Path(manifest['work'])
    with tarfile.open(output / 'disposable-artifacts.tar.gz', 'w:gz') as archive:
        archive.add(work, arcname=work.name)
    measure.write_json(output / 'final-artifact-hashes.json',
                       {str(p.relative_to(output)): measure.sha(p) for p in sorted(output.rglob('*'))
                        if p.is_file() and p.name != 'final-artifact-hashes.json'})
    print('Runtime unchanged; exact disposable sources/binaries retained; assembly generated after timing')


if __name__ == '__main__':
    main()
