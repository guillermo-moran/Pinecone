"""Check independent work ledger and full-state agreement across final arms."""
import json
from pathlib import Path
import sys
import measure


def main():
    output = Path(sys.argv[1]).resolve()
    rows = [json.loads(line) for line in (output / 'verification.jsonl').read_text().splitlines()]
    state, ledgers = {}, []
    for row in rows:
        assert row['returncode'] == 0
        r = row['result']
        key = (r['workload'], r['steps'])
        value = (r['cpu_hex'], r['ram_fnv64'], r['status'])
        assert state.setdefault(key, value) == value
        assert r['full_cpu_asserted'] and r['full_ram_asserted'] and r['memory_faults'] == 0
        if 'ledger' not in r:
            continue
        d = r['ledger']
        assert d['chain_entries'] == 1 and r['max_checkpoint_steps'] <= 4096
        assert sum(d['executed_hist'].values()) == d['prototype_entries']
        assert sum(int(n) * count for n, count in d['executed_hist'].items()) == d['prototype_steps']
        assert sum(d['status_hist'].values()) == d['prototype_entries']
        assert not (set(d['status_hist']) - {'max_steps', 'revalidate'})
        # generic_dispatches counts only the generic fallback, not all C handlers.
        assert d['prototype_steps'] <= r['steps']
        assert (r['steps'] == d['prototype_steps']) == (d['established_entries'] == 0)
        if row['arm'] == 'established-superblock-off':
            assert r['mode'] == 0 and r['superblocks'] == 0
        if r['workload'] == 'memory':
            cold = 1 - r['warm']
            assert d['hot_reads'] == d['hot_writes'] == 250000 - cold
            assert d['full_reads'] == d['full_writes'] == cold
            assert d['commit_calls'] == 250000 - cold
            assert d['translation_callbacks'] == 2 * cold
            assert r['invalidation_checks'] == r['invalidation_skips'] == 250000
            assert r['invalidations'] == 0
            assert d['status_hist'].get('revalidate', 0) == (2 * cold if r['mode'] == 2 else 0)
        if r['workload'] == 'arithmetic' and r['mode'] == 1:
            assert d['prototype_steps'] == 1000000
            expected = d['prototype_entries']
            if row['arm'] != 'cost-validation-entry-only':
                expected += d['prototype_steps']
            assert d['validations'] == expected
        ledgers.append({'arm': row['arm'], 'workload': r['workload'], 'mode': r['mode'],
                        'warm': r['warm'], 'prototype_entries': d['prototype_entries'],
                        'prototype_steps': d['prototype_steps'], 'established_entries': d['established_entries'],
                        'established_steps_by_subtraction': r['steps'] - d['prototype_steps'],
                        'validations': d['validations'], 'checkpoints': r['checkpoints'],
                        'superblocks': r['superblocks'], 'status_hist': d['status_hist']})
    measure.write_json(output / 'verification-audit.json', {'passed': True, 'records': len(rows),
        'prefix_cases': len(rows) - len(ledgers), 'million_step_ledgers': len(ledgers),
        'verification_sha256': measure.sha(output / 'verification.jsonl'), 'ledger_summary': ledgers})
    print('PASS', len(rows), 'records;', len(ledgers), 'independent million-step ledgers')


if __name__ == '__main__':
    main()
