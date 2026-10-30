"""Summarize this fixed two-loop experiment; no native execution."""
import json
from pathlib import Path
import random
import statistics as st
import sys
import measure


def interval(values):
    rng = random.Random(104729)
    medians = sorted(st.median(rng.choices(values, k=len(values))) for _ in range(20000))
    return [medians[500], medians[19499]]


def main():
    output = Path(sys.argv[1]).resolve()
    status = json.loads((output / 'timing-status.json').read_text())
    if status['status'] != 'complete':
        raise ValueError('No attribution from incomplete or load-contaminated cohort')
    rows = [json.loads(line) for line in (output / 'timings.jsonl').read_text().splitlines()]
    data = {}
    for row in rows:
        r = row['result']
        key = (row['arm'], r['workload'], r['mode'], r['warm'])
        data.setdefault(key, {})[row['round']] = r['wall_ns'] / 1e6
    def series(arm, work, mode, warm):
        return data[(arm, work, mode, warm)]
    effects = []
    for work, prototype in [('arithmetic', 1), ('memory', 2)]:
        for warm in [0, 1]:
            c = series('baseline', work, 0, warm)
            tp = series('baseline', work, prototype, warm)
            for arm in ['prototype-limit-4', 'prototype-limit-16', 'prototype-limit-64',
                        'prototype-limit-256', 'prototype-limit-4096',
                        'cost-validation-entry-only', 'cost-prototype-stats-off', 'cost-memory-stats-off']:
                if (arm, work, prototype, warm) not in data:
                    continue
                candidate = series(arm, work, prototype, warm)
                if arm.startswith('prototype-limit-'):
                    reference = series('prototype-limit-4', work, prototype, warm)
                    effects_ms = [reference[i] - candidate[i] for i in c]
                    gaps = [candidate[i] - c[i] for i in c]
                    contrast = 'prototype-limit-4 minus candidate; C fixed baseline'
                else:
                    ref = 'cost-memory-stats-on' if arm == 'cost-memory-stats-off' else 'cost-reference'
                    rc, rt = series(ref, work, 0, warm), series(ref, work, prototype, warm)
                    ac = series(arm, work, 0, warm)
                    effects_ms = [(rt[i] - rc[i]) - (candidate[i] - ac[i]) for i in c]
                    gaps = [candidate[i] - ac[i] for i in c]
                    contrast = ref + ' executor gap minus candidate executor gap'
                assert len(effects_ms) >= 9
                effects.append({'workload': work, 'warm': warm, 'arm': arm,
                                'contrast': contrast, 'paired_gap_reduction_median_ms': st.median(effects_ms),
                                'bootstrap95_median_ms': interval(effects_ms),
                                'paired_candidate_gap_median_ms': st.median(gaps),
                                'paired_baseline_gap_median_ms': st.median(tp[i]-c[i] for i in c),
                                'paired_effects_ms': effects_ms, 'n': len(effects_ms)})
    effects.sort(key=lambda x: (x['workload'], x['warm'], -x['paired_gap_reduction_median_ms']))
    measure.write_json(output / 'contrasts.json', {'cohort': status, 'effects': effects,
        'uncertainty': 'Seeded percentile bootstrap of median paired round differences; n=11, descriptive only, no multiplicity correction or host-cycle attribution.'})
    for effect in effects:
        if effect['warm']:
            print(effect['workload'], effect['arm'], round(effect['paired_gap_reduction_median_ms'], 4),
                  [round(x, 4) for x in effect['bootstrap95_median_ms']])


if __name__ == '__main__':
    main()
