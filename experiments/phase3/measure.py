#!/usr/bin/env python3
"""Bounded, reversible host-only benchmark. Never installs or resets the VM."""
import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import time


def processes():
    rows = subprocess.check_output(
        ['ps', '-axo', 'pid=,pcpu=,state=,comm='], text=True).splitlines()
    return [dict(zip(('pid', 'cpu', 'state', 'command'), row.split(None, 3)))
            for row in rows if row.strip()]


def identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=', '-o', 'comm='],
                            text=True, capture_output=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def load_gate():
    rows = processes()
    active = [r for r in rows if 'T' not in r['state']]
    peak = max((float(r['cpu']) for r in active), default=0)
    total = sum(float(r['cpu']) for r in active)
    vm_running = any(r['command'].endswith('/Pinecone.app/Pinecone') for r in active)
    build_tools = {'clang', 'clang++', 'swift-frontend', 'swiftc', 'swift-build',
                   'swift-test', 'xcodebuild', 'ld', 'ld64.lld'}
    competing = []
    for row in active:
        command = Path(row['command'])
        if (command.name in build_tools
                or (command.name in {'test', 'test-enabled'}
                    and command.parent.name.startswith('pinecone-'))
                or '.xctest/Contents/MacOS/' in str(command)):
            competing.append(row)
    return {'utc': time.time(), 'peak_cpu': peak, 'total_cpu': total,
            'passed': not vm_running and not competing and peak <= 100 and total <= 400,
            'competing_work': competing, 'processes': rows}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pause-simulator-pid', type=int)
    parser.add_argument('--load-wait-seconds', type=int, default=0,
                        help='Wait up to 120 seconds for three consecutive passing load checks')
    parser.add_argument('--suite', choices=('register', 'memory', 'entry', 'chain', 'hot', 'address', 'pair', 'indirect', 'conditional'), default='register')
    args = parser.parse_args()
    if not 0 <= args.load_wait_seconds <= 120:
        parser.error('--load-wait-seconds must be between 0 and 120')
    args.output.mkdir(parents=True, exist_ok=False)
    binary = args.binary.resolve()
    root = Path(__file__).resolve().parents[2]
    inputs = list((root / 'experiments/phase3').glob('*.c'))
    inputs += list((root / 'experiments/phase3').glob('*.h'))
    inputs += list((root / 'experiments/phase3').glob('*.S'))
    inputs += list((root / 'Sources/ARM64VizNative').rglob('*.h'))
    inputs += list((root / 'Sources/ARM64VizNative').rglob('*.c'))
    inputs += list((root / 'Sources/ARM64VizNative').rglob('*.S'))
    inputs += [Path(__file__).resolve(), root / 'experiments/phase3/run.sh']
    report = {'binary': str(binary), 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'sources': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
              'load_policy': 'Pinecone stopped/absent; no detected compiler/linker/test; active peak <=100%, total <=400%',
              'suite': args.suite, 'load': [], 'accepted': False, 'resumed': False}
    paused_identity = None
    try:
        if args.pause_simulator_pid:
            pid = args.pause_simulator_pid
            row = next((r for r in processes() if int(r['pid']) == pid), None)
            if not row or '/CoreSimulator/Devices/' not in row['command'] or not row['command'].endswith('/Pinecone.app/Pinecone'):
                raise RuntimeError('Refusing to pause anything other than the specified Pinecone Simulator app')
            if 'T' in row['state']:
                raise RuntimeError('App was already suspended; do not take ownership of its resume')
            paused_identity = identity(pid)
            if not paused_identity:
                raise RuntimeError('App exited before pause')
            os.kill(pid, signal.SIGSTOP)
            report['paused_identity'] = paused_identity
        load_deadline = time.monotonic() + args.load_wait_seconds
        consecutive = 0
        while consecutive < 3:
            time.sleep(1)
            check = load_gate(); report['load'].append(check)
            consecutive = consecutive + 1 if check['passed'] else 0
            if not check['passed'] and time.monotonic() >= load_deadline:
                raise RuntimeError('Host load gate failed; no timing accepted')
        command = {'register': '--benchmark', 'memory': '--benchmark-memory',
                   'chain': '--benchmark-chain', 'hot': '--benchmark-hot',
                   'address': '--benchmark-address', 'pair': '--benchmark-pair',
                   'indirect': '--benchmark-indirect', 'entry': '--benchmark-entry',
                   'conditional': '--benchmark-conditional'}[args.suite]
        result = subprocess.run([str(binary), command], text=True,
                                capture_output=True, timeout=180, check=False)
        (args.output / 'samples.csv').write_text(result.stdout)
        (args.output / 'stderr.txt').write_text(result.stderr)
        report['returncode'] = result.returncode
        check = load_gate(); report['load'].append(check)
        if result.returncode or not check['passed']:
            raise RuntimeError('Benchmark or post-run load gate failed')
        rows = list(csv.DictReader(io.StringIO(result.stdout)))
        workloads = {'memory': ('load64', 'store64', 'mixed64'), 'entry': ('load64', 'store64', 'mixed64'), 'register': ('arithmetic', 'branch'),
                     'hot': ('shifted', 'masks'),
                     'address': ('unscaled64', 'indexed64', 'register_signed8'),
                     'pair': ('pair64', 'pairindexed64', 'pairsigned32'),
                     'indirect': ('indirect', 'call_return'),
                     'conditional': ('conditional_select', 'conditional_compare'),
                     'chain': ('ring2', 'ring8', 'ring32', 'ring128')}[args.suite]
        modes = {'hot': (0, 2, 3, 4), 'indirect': (0, 2, 3, 4), 'conditional': (0, 2, 3, 4), 'address': (0, 2), 'pair': (0, 2), 'memory': range(3),
                 'register': range(5), 'chain': range(2), 'entry': (2, 3)}[args.suite]
        expected = {(work, str(window), str(round_), str(mode))
                    for work in workloads for window in (4, 64, 256, 4096)
                    for round_ in range(15) for mode in modes}
        keys = [(r['workload'], r['window'], r['round'], r['mode']) for r in rows]
        if len(rows) != len(expected) or set(keys) != expected or any(int(r['steps']) != 1048576 for r in rows):
            raise RuntimeError('Incomplete or duplicate sample cohort')
        groups = {}
        for r in rows:
            key = '/'.join((r['workload'], r['window'], r['mode']))
            groups.setdefault(key, []).append(r)
        report['summary'] = {}
        if args.suite == 'chain':
            events = list(csv.reader(io.StringIO(result.stderr)))
            expected_events = {(str(length), str(round_), str(mode))
                               for length in (4, 16) for round_ in range(101) for mode in range(2)}
            if (len(events) != len(expected_events) or any(len(e) != 6 or e[0] != 'EVENT' for e in events)
                    or {tuple(e[1:4]) for e in events} != expected_events):
                raise RuntimeError('Incomplete event-service cohort')
            report['event_service'] = {}
            for length in (4, 16):
                for mode in range(2):
                    samples = sorted(int(e[5]) for e in events if (e[1], e[3]) == (str(length), str(mode)))
                    report['event_service'][f'{length}/{mode}'] = {
                        'median_ns': statistics.median(samples), 'p95_ns': samples[95], 'max_ns': max(samples)}
        for key, samples in groups.items():
            wall = [int(r['wall_ns']) / 1e6 for r in samples]
            cpu = [int(r['cpu_ns']) / 1e6 for r in samples]
            q = statistics.quantiles(wall, n=4)
            report['summary'][key] = {'wall_ms_median': statistics.median(wall),
                'wall_ms_min': min(wall), 'wall_ms_max': max(wall), 'wall_ms_iqr': q[2] - q[0],
                'cpu_ms_median': statistics.median(cpu)}
        if args.suite == 'entry':
            report['paired_entry'] = {}
            for work in workloads:
                for window in (4, 64, 256, 4096):
                    samples = {(r['round'], r['mode']): r for r in rows
                               if r['workload'] == work and r['window'] == str(window)}
                    ratios = [int(samples[str(i), '2']['wall_ns']) /
                              int(samples[str(i), '3']['wall_ns']) for i in range(15)]
                    q = statistics.quantiles(ratios, n=4)
                    report['paired_entry'][f'{work}/{window}'] = {
                        'inline_over_outline_by_round': ratios,
                        'median': statistics.median(ratios), 'iqr': q[2] - q[0]}
        report['accepted'] = True
        print(json.dumps(report['summary'], indent=2))
    finally:
        if paused_identity and identity(args.pause_simulator_pid) == paused_identity:
            os.kill(args.pause_simulator_pid, signal.SIGCONT)
            report['resumed'] = True
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit('terminated')))
    main()
