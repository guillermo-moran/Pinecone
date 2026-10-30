"""Prepare NEW cohort metadata using existing frozen binaries; never run them.

No compilation, timing, native execution or Simulator operation. Never copies
timing samples, load evidence, summaries or restoration state.
"""
import json
from pathlib import Path
import shutil
import sys
import measure


def main():
    old, new = (Path(p).resolve() for p in sys.argv[1:])
    results = (measure.HERE / 'results').resolve()
    if old == new or new.parent != results or new.exists():
        raise ValueError('Destination must be a new direct child of experiments/phase1/results')
    bundle = json.loads((old / 'review-bundle.json').read_text())
    ids = list(bundle['arms'])
    assert bundle == measure.review_bundle(old, ids, save=False), 'old frozen artifact/tool drift'
    review = (measure.HERE / 'review.md').read_text()
    assert 'ACCEPTED_BUNDLE_SHA256: ' + measure.sha(old / 'review-bundle.json') in review.splitlines()
    new.mkdir()
    filenames = ['manifest.json', 'verification.jsonl', 'verification-audit.json',
                 'preparation-rejections.json', 'test-ledger-status.json', 'test-ledger-build.json',
                 'test_ledger.c', 'archive-hash.json']
    for filename in filenames:
        shutil.copyfile(old / filename, new / filename)
    for id_ in ids:
        shutil.copytree(old / id_, new / id_)
    measure.write_json(new / 'cohort-origin.json', {
        'original_run': str(old), 'original_review_bundle_sha256': measure.sha(old / 'review-bundle.json'),
        'frozen_artifacts_reused': True, 'new_native_runs': 0,
        'timing_samples_copied': 0, 'policy': 'Complete fresh eleven-round cohort; never selective replacement',
        'review_required': 'New bundle binds a new output directory; reviewer/parent must renew approval',
        'simulator': 'No action performed; parent must coordinate any future stop and restore grant'})
    measure.review_bundle(new, ids)
    print('Prepared metadata only:', new)
    print('After new exact-bundle acceptance and parent VM/load coordination:')
    print('python3 experiments/phase1/measure.py time', new, *ids, '--samples 11')


if __name__ == '__main__':
    main()
