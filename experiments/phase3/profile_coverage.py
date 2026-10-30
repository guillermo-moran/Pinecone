#!/usr/bin/env python3
"""Classify retained PC prefixes, never estimate retired-instruction coverage."""
import argparse
import collections
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('profiles', type=Path, nargs='+')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    header = (root / 'Sources/ARM64VizNative/include/ARM64VizNative.h').read_text()
    names = {int(number): name for name, number in
             re.findall(r'AVZ_NATIVE_OP_(\w+)\s*=\s*(\d+)', header)}
    reports = [(p, json.loads(p.read_text())) for p in args.profiles]
    words = set()
    for _, report in reports:
        for key in ('hotPCs', 'secondaryHotPCs'):
            for entry in report.get(key, []):
                for word in entry['instructions'].split():
                    if not re.fullmatch('[0-9a-fA-F]{8}', word):
                        parser.error(f'invalid instruction: {word!r}')
                    words.add(word.lower())
    if not words:
        parser.error('no sampled instruction prefixes')
    result = subprocess.run([str(args.binary.resolve()), '--classify'],
                            input='\n'.join(sorted(words)) + '\n',
                            capture_output=True, text=True, check=True, timeout=30)
    decoded = {}
    for row in csv.reader(io.StringIO(result.stdout)):
        word, kind, bits, flags, shift, amount, supported = row
        decoded[word] = {'kind': names.get(int(kind), 'UNKNOWN'), 'bits': int(bits),
                         'flags': int(flags), 'shift': int(shift), 'amount': int(amount),
                         'supported': bool(int(supported))}
    if set(decoded) != words:
        raise ValueError('incomplete classifier output')
    output = {'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              'warning': 'Unweighted retained block prefixes only (up to four words). '
                         'Space-Saving sample counters are estimates; CPU windows may differ. '
                         'This is neither a retired histogram nor an end-to-end speed result.',
              'profiles': []}
    for path, report in reports:
        item = {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'cpus': {}}
        for key in ('hotPCs', 'secondaryHotPCs'):
            counts, missing = collections.Counter(), collections.Counter()
            fully_supported = 0
            entries = report.get(key, [])
            for entry in entries:
                prefix = [decoded[w.lower()] for w in entry['instructions'].split()]
                for d in prefix:
                    counts[d['kind']] += 1
                first = next((d for d in prefix if not d['supported']), None)
                if first:
                    missing[first['kind']] += 1
                elif prefix:
                    fully_supported += 1
            item['cpus'][key] = {'retained_prefixes': len(entries),
                                'fully_supported_prefixes': fully_supported,
                                'word_occurrences_by_kind': dict(counts.most_common()),
                                'first_missing_kind_by_prefix': dict(missing.most_common())}
        output['profiles'].append(item)
    output['words'] = decoded
    print(json.dumps(output, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
