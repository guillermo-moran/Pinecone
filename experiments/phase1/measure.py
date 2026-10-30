#!/usr/bin/env python3
"""Sole-owner native measurement driver. All runtime edits are disposable copies.

Commands: freeze; prepare RUN [VARIANT...]; verify RUN [VARIANT...];
          time RUN [VARIANT...] [--samples 11]; summarize RUN.
Review acceptance and live process gates apply even to baseline timing.
"""
import argparse
import difflib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FLAGS = ['-std=c11', '-O3', '-DAVZ_THREADED_PROTOTYPE_ENABLE=1',
         '-DAVZ_PHASE1_OFFLINE_COST_CONTROL=1']
MODULES = ['prepare_boundaries', 'prepare_cost_controls']
BUDGETS = list(range(1, 18)) + [63, 64, 65, 255, 256, 257, 4095, 4096, 4097, 8191, 8192, 8193]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def hashes(root):
    return {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob('*')) if p.is_file()}


def invoke(command, cwd=None, env=None):
    p = subprocess.run([str(x) for x in command], cwd=cwd, env=env,
                       capture_output=True, text=True, timeout=180)
    return {'command': [str(x) for x in command], 'returncode': p.returncode,
            'stdout': p.stdout, 'stderr': p.stderr}


def checked(command, **kw):
    r = invoke(command, **kw)
    if r['returncode']:
        raise RuntimeError(r)
    return r['stdout'].strip()


def copy_file(source, target):
    if source.is_symlink() or not source.is_file():
        raise ValueError(f'not a regular source: {source}')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    assert target.stat().st_nlink == 1 and source.stat().st_ino != target.stat().st_ino


def freeze():
    name = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    output = HERE / 'results' / name
    output.mkdir(parents=True, exist_ok=False)
    work = Path(tempfile.mkdtemp(prefix='arm64viz-phase1-attribution.', dir='/private/tmp'))
    frozen = work / 'frozen'
    sources = list((ROOT / 'Sources/ARM64VizNative').rglob('*'))
    sources += list((ROOT / 'scripts').glob('*threaded*'))
    sources += [ROOT / 'Package.swift']
    for source in sources:
        if source.is_file():
            copy_file(source, frozen / source.relative_to(ROOT))
    for filename in ['fixture.c', 'ledger.h']:
        copy_file(HERE / filename, frozen / 'experiments/phase1' / filename)
    marker = {'offline': True, 'single_thread': True, 'immutable_guest_code': True,
              'cost_controls': {'fixture': 'threaded-runtime-regression-benchmarks-v1',
              'single_thread': True, 'immutable_guest_code': True,
              'no_external_writers': True, 'no_invalidation': True,
              'invocation_policy': 'decoded-block-count',
              'allowed_modes': ['--dispatch-benchmark', '--benchmark']}}
    write_json(frozen / '.pinecone-phase1-snapshot', marker)
    manifest = {'schema': 1, 'created_utc': name, 'work': str(work),
                'source_root': str(ROOT), 'frozen': str(frozen),
                'source_hashes': hashes(frozen),
                'git_head': checked(['git', 'rev-parse', 'HEAD'], cwd=ROOT),
                'git_status': checked(['git', 'status', '--short'], cwd=ROOT),
                'git_diff': checked(['git', 'diff', '--', 'Sources', 'scripts', 'Apps'], cwd=ROOT),
                'compiler_path': shutil.which('clang'), 'compiler': checked(['clang', '--version']),
                'sdk': checked(['xcrun', '--show-sdk-path']), 'host': platform.uname()._asdict(),
                'flags': FLAGS, 'environment': {k: v for k, v in os.environ.items()
                    if k.startswith(('PINECONE_', 'AVZ_', 'SIMCTL_CHILD_PINECONE_', 'CC', 'CFLAGS', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET'))},
                'tool_hashes': {p.name: sha(p) for p in HERE.glob('*.py')},
                'report_hashes': {p.name: sha(p) for p in (ROOT / 'docs').glob('phase1-*.md')},
                'sampling': {'samples_per_arm': 11, 'order': 'forward/reverse alternating rounds',
                             'steps': 1000000, 'warmup_steps': 8192,
                             'load_policy': '3 ps snapshots 2s apart: Pinecone absent; max process <=100% CPU; total <=400% CPU',
                             'statistics': 'median, min/max, IQR, paired per-round gap changes; no cycle claims'}}
    write_json(output / 'manifest.json', manifest)
    with tarfile.open(output / 'frozen-source.tar.gz', 'w:gz') as archive:
        archive.add(frozen, arcname='frozen')
    write_json(output / 'archive-hash.json', {'frozen-source.tar.gz': sha(output / 'frozen-source.tar.gz')})
    print(output, flush=True)
    return output


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def catalog():
    entries = {'baseline': (None, {'id': 'baseline', 'description': 'unchanged dirty frozen sources'})}
    for name in MODULES:
        if not (HERE / (name + '.py')).exists():
            continue
        mod = load_module(name)
        for variant in mod.variants():
            entries[variant['id']] = (name, variant)
    return entries


def source_diff(before, after):
    diff = []
    for p in sorted(after.rglob('*')):
        if not p.is_file():
            continue
        rel = p.relative_to(after)
        old = before / rel
        if old.exists() and sha(old) == sha(p):
            continue
        try:
            a = old.read_text().splitlines(True) if old.exists() else []
            b = p.read_text().splitlines(True)
        except UnicodeError:
            continue
        diff.extend(difflib.unified_diff(a, b, fromfile='before/' + str(rel), tofile='after/' + str(rel)))
    return ''.join(diff)


def build(tree, output, ledger=False):
    n = tree / 'Sources/ARM64VizNative'
    cmd = [shutil.which('clang'), *FLAGS, '-include', tree / 'experiments/phase1/ledger.h']
    if ledger:
        cmd += ['-DP1_LEDGER=1']
    cmd += ['-I', n / 'include', '-I', n, tree / 'experiments/phase1/fixture.c',
            n / 'ARM64VizBlockCache.c', n / 'ARM64VizGuestMemory.c',
            n / 'ARM64VizThreadedPrototype.c', '-lm', '-o', output]
    r = invoke(cmd)
    write_json(output.with_suffix('.build.json'), r)
    if r['returncode']:
        raise RuntimeError(r['stderr'])
    return {'command': r['command'], 'binary_sha256': sha(output)}


def prepare(output, ids):
    manifest = json.loads((output / 'manifest.json').read_text())
    frozen = Path(manifest['frozen'])
    assert hashes(frozen) == manifest['source_hashes'], 'frozen source changed'
    cat = catalog()
    for id_ in ids:
        artifact = output / id_
        artifact.mkdir(exist_ok=False)
        arm = Path(manifest['work']) / 'arms' / id_
        timing = arm / 'timing'
        shutil.copytree(frozen, timing)
        module_name, description = cat[id_]
        summary = {}
        if module_name:
            summary = load_module(module_name).prepare(timing, id_)
        (artifact / 'control.diff').write_text(source_diff(frozen, timing))
        ledger = arm / 'ledger'
        shutil.copytree(timing, ledger)
        diagnostic = load_module('instrument_ledger').instrument(ledger)
        (artifact / 'ledger.diff').write_text(source_diff(timing, ledger))
        data = {'id': id_, 'description': description, 'prepare_summary': summary,
                'module': module_name, 'module_sha256': sha(HERE / (module_name + '.py')) if module_name else None,
                'timing_tree': str(timing), 'ledger_tree': str(ledger),
                'timing_source_hashes': hashes(timing), 'ledger_source_hashes': hashes(ledger),
                'diagnostic_changes': diagnostic, 'builds': {}}
        write_json(artifact / 'arm.json', data)
        for kind, tree in [('timing', timing), ('ledger', ledger)]:
            binary = arm / (kind + '-fixture')
            data['builds'][kind] = {'binary': str(binary), **build(tree, binary, kind == 'ledger')}
            write_json(artifact / 'arm.json', data)
        print('prepared', id_, flush=True)


def settings(id_):
    stats = 0 if id_ == 'cost-memory-stats-off' else 1
    workloads = ['memory'] if id_.startswith('cost-memory-stats-') else ['arithmetic', 'memory']
    if id_ in ['cost-validation-entry-only', 'cost-prototype-stats-off']:
        workloads = ['arithmetic']
    return stats, workloads


def modes_for(id_, workload):
    if id_ == 'established-superblock-off':
        return [0]
    if id_.startswith('prototype-limit-'):
        return [1] if workload == 'arithmetic' else [2]
    return [0, 1] if workload == 'arithmetic' else [0, 1, 2]


def sample(output, id_, kind, workload, mode, warm, budget, timed, round_=None):
    artifact = output / id_
    arm = json.loads((artifact / 'arm.json').read_text())
    binary = Path(arm['builds'][kind]['binary'])
    assert sha(binary) == arm['builds'][kind]['binary_sha256']
    stats, _ = settings(id_)
    summary = arm['prepare_summary']
    if 'detailed_memory_statistics' in summary:
        assert stats == summary['detailed_memory_statistics'], 'fixture setting differs from reviewed metadata'
        required_mode = '--benchmark' if workload == 'memory' else '--dispatch-benchmark'
        assert required_mode in summary['allowed_modes'], 'fixture outside reviewed workload scope'
        assert all('-D' + flag in FLAGS for flag in summary['required_compile_defines'])
    command = [binary, workload, str(mode), str(int(warm)), str(stats), str(budget), str(int(timed))]
    r = invoke(command, env={**os.environ, 'PINECONE_THREADED_PROTOTYPE': '0', 'PINECONE_THREADED_MEMORY': '0'})
    record = {'arm': id_, 'kind': kind, 'round': round_, **r}
    if r['returncode'] == 0:
        record['result'] = json.loads(r['stdout'])
    with (output / ('timings.jsonl' if timed else 'verification.jsonl')).open('a') as f:
        f.write(json.dumps(record) + '\n')
    if r['returncode']:
        raise RuntimeError(record)
    return record['result']


def verify(output, ids):
    for id_ in ids:
        stats, workloads = settings(id_)
        for workload in workloads:
            modes = modes_for(id_, workload)
            for warm in [False, True]:
                for mode in modes:
                    for budget in BUDGETS:
                        sample(output, id_, 'timing', workload, mode, warm, budget, False)
                    sample(output, id_, 'ledger', workload, mode, warm, 1000000, False)
        write_json(output / id_ / 'verified.json', {'partial_budgets': BUDGETS,
                   'warm_and_cold': True, 'checkpoint_limit': 4096,
                   'ledger_steps': 1000000, 'passed': True,
                   'arm_sha256': sha(output / id_ / 'arm.json')})
        print('verified', id_, flush=True)


def load_gate(output, label, intervals=3):
    evidence = []
    for i in range(intervals):
        r = invoke(['ps', '-axo', 'pid,ppid,%cpu,etime,comm'])
        if r['returncode']:
            write_json(output / (label + '-load.json'), r)
            raise RuntimeError('process inventory unavailable; timing forbidden')
        rows = []
        for line in r['stdout'].splitlines()[1:]:
            fields = line.split(None, 4)
            if len(fields) == 5:
                rows.append({'pid': int(fields[0]), 'ppid': int(fields[1]),
                             'cpu': float(fields[2]), 'elapsed': fields[3], 'comm': fields[4]})
        total = sum(row['cpu'] for row in rows)
        pinecone = [row for row in rows if row['comm'].endswith('/Pinecone')]
        high = [row for row in rows if row['cpu'] > 100]
        evidence.append({'utc': time.time(), 'loadavg': os.getloadavg(), 'rows': rows,
                         'total_cpu': total, 'pinecone': pinecone, 'high_cpu': high})
        if i + 1 < intervals:
            time.sleep(2)
    write_json(output / (label + '-load.json'), evidence)
    if any(e['pinecone'] or e['high_cpu'] or e['total_cpu'] > 400 for e in evidence):
        raise RuntimeError('VM/load gate failed; no timing authorized by runner')


def review_bundle(output, ids, save=True):
    bundle = {'run': str(output), 'manifest_sha256': sha(output / 'manifest.json'),
              'tool_hashes': {name: sha(HERE / name) for name in
                 ['measure.py', 'fixture.c', 'ledger.h', 'instrument_ledger.py',
                  'test_preparation.py', 'test_ledger.c', 'audit_verification.py']},
              'evidence_hashes': {name: sha(output / name) for name in
                 ['verification.jsonl', 'verification-audit.json', 'preparation-rejections.json',
                  'test-ledger-status.json', 'test-ledger-build.json']}, 'arms': {}}
    for id_ in ids:
        arm = json.loads((output / id_ / 'arm.json').read_text())
        verified = json.loads((output / id_ / 'verified.json').read_text())
        assert verified['passed'] and verified['arm_sha256'] == sha(output / id_ / 'arm.json')
        for kind in ['timing', 'ledger']:
            assert hashes(Path(arm[kind + '_tree'])) == arm[kind + '_source_hashes']
            b = arm['builds'][kind]
            assert sha(Path(b['binary'])) == b['binary_sha256']
        for filename in ['fixture.c', 'ledger.h']:
            assert sha(HERE / filename) == arm['timing_source_hashes']['experiments/phase1/' + filename]
        if arm['module']:
            assert sha(HERE / (arm['module'] + '.py')) == arm['module_sha256']
        bundle['arms'][id_] = {'arm_sha256': sha(output / id_ / 'arm.json'),
                               'verified_sha256': sha(output / id_ / 'verified.json')}
    if save:
        write_json(output / 'review-bundle.json', bundle)
        print('review-bundle SHA256', sha(output / 'review-bundle.json'), flush=True)
    return bundle


def timing(output, ids, samples):
    if samples < 9:
        raise ValueError('at least 9 samples required')
    review = HERE / 'review.md'
    text = review.read_text()
    accepted = set()
    for line in text.splitlines():
        if line.startswith('ACCEPTED_FOR_TIMING:'):
            accepted.update(x.strip() for x in line.split(':', 1)[1].split(','))
    if not set(ids).issubset(accepted):
        raise RuntimeError(f'review not accepted: {set(ids) - accepted}')
    bundle_path = output / 'review-bundle.json'
    bundle = json.loads(bundle_path.read_text())
    assert bundle == review_bundle(output, list(bundle['arms']), save=False), 'approved bundle drift'
    assert set(ids).issubset(bundle['arms'])
    if f'ACCEPTED_BUNDLE_SHA256: {sha(bundle_path)}' not in text.splitlines():
        raise RuntimeError('exact source/fixture/tool/build/verification bundle not accepted')
    for id_ in ids:
        arm = json.loads((output / id_ / 'arm.json').read_text())
        assert json.loads((output / id_ / 'verified.json').read_text())['passed']
        assert hashes(Path(arm['timing_tree'])) == arm['timing_source_hashes']
        if arm['module']:
            assert sha(HERE / (arm['module'] + '.py')) == arm['module_sha256']
    write_json(output / 'timing-approval.json', {'review_sha256': sha(review), 'review': text,
               'ids': ids, 'samples': samples, 'started': time.time()})
    load_gate(output, 'pre-timing')
    # Never append a fresh cohort to an earlier partial/failed cohort.
    if (output / 'timings.jsonl').exists():
        raise RuntimeError('timing cohort already exists; preserve it and create a fresh run')
    write_json(output / 'timing-status.json', {'status': 'in_progress'})
    for workload in ['arithmetic', 'memory']:
        for warm in [False, True]:
            arms = [(id_, mode) for id_ in ids if workload in settings(id_)[1]
                    for mode in modes_for(id_, workload)]
            if not arms:
                continue
            for round_ in range(samples):
                load_gate(output, f'{workload}-{int(warm)}-{round_}-before', intervals=1)
                for id_, mode in (arms if round_ % 2 == 0 else list(reversed(arms))):
                    sample(output, id_, 'timing', workload, mode, warm, 1000000, True, round_)
                try:
                    load_gate(output, f'{workload}-{int(warm)}-{round_}-after', intervals=1)
                except Exception:
                    write_json(output / 'timing-status.json', {'status': 'invalid_load',
                               'workload': workload, 'warm': warm, 'round': round_})
                    raise
            print('timed', workload, 'warm' if warm else 'cold', flush=True)
    write_json(output / 'timing-status.json', {'status': 'complete'})
    summarize(output)


def summarize(output):
    groups = {}
    path = output / 'timings.jsonl'
    if not path.exists():
        write_json(output / 'summary.json', {'status': 'no timings', 'groups': {}})
        return
    for line in path.read_text().splitlines():
        rec = json.loads(line)
        if 'result' not in rec:
            continue
        r = rec['result']
        key = '/'.join(map(str, [rec['arm'], r['workload'], r['mode'], r['warm']]))
        groups.setdefault(key, []).append(r['wall_ns'] / 1e6)
    summary = {}
    for key, values in groups.items():
        q = statistics.quantiles(values, n=4) if len(values) > 1 else [values[0]] * 3
        summary[key] = {'n': len(values), 'median_ms': statistics.median(values),
                        'min_ms': min(values), 'max_ms': max(values), 'iqr_ms': q[2]-q[0], 'samples_ms': values}
    status = json.loads((output / 'timing-status.json').read_text())
    write_json(output / 'summary.json', {'cohort': status, 'groups': summary,
               'eligible_for_attribution': status['status'] == 'complete' and all(v['n'] >= 9 for v in summary.values())})


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['freeze', 'prepare', 'verify', 'review-bundle', 'time', 'summarize'])
    p.add_argument('run', nargs='?', type=Path)
    p.add_argument('variants', nargs='*')
    p.add_argument('--samples', type=int, default=11)
    a = p.parse_args()
    if a.action == 'freeze':
        freeze(); return
    if a.run is None:
        p.error('RUN directory required')
    output = a.run.resolve()
    try:
        if a.action == 'prepare': prepare(output, a.variants or ['baseline'])
        elif a.action == 'verify': verify(output, a.variants or ['baseline'])
        elif a.action == 'review-bundle': review_bundle(output, a.variants or ['baseline'])
        elif a.action == 'time': timing(output, a.variants or ['baseline'], a.samples)
        else: summarize(output)
    except Exception as e:
        with (output / 'failures.jsonl').open('a') as f:
            f.write(json.dumps({'utc': time.time(), 'action': a.action, 'variants': a.variants, 'error': str(e)}) + '\n')
        raise


if __name__ == '__main__':
    main()
