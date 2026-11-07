#!/usr/bin/env python3
import csv
import json
from collections import Counter
from datetime import date
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
rows = list(csv.DictReader((ROOT / 'corpus.csv').open()))
required = [
    'id','date','protocol','chain','family','mechanism','gross_or_nominal_impact',
    'net_bad_debt_or_realized_impact','recovery_or_reconciliation','source','confidence',
    'raw_balance_or_cap','spike_or_deviation_check','issuer_affiliate_asset',
    'pinned_reproducer_value','audit_reuse',
]
assert len(rows) == 49, len(rows)
assert list(rows[0]) == required
ids = [r['id'] for r in rows]
assert ids == [f'I-{i:03d}' for i in range(1, 50)]
for r in rows:
    date.fromisoformat(r['date'])
    assert r['confidence'] in {'A','B','C'}
    assert all(r[k] in {'true','false'} for k in required[-5:-1])
    assert urlparse(r['source']).scheme == 'https' and urlparse(r['source']).netloc
    assert r['audit_reuse']
    if r['date'].startswith('2026-'):
        assert 'NO_REPRODUCTION' in r['audit_reuse'] or 'EXCLUDED_2026_REPRODUCTION' in r['audit_reuse']

summary = {
    'status': 'PASS',
    'entries': len(rows),
    'years': dict(sorted(Counter(r['date'][:4] for r in rows).items())),
    'confidence': dict(sorted(Counter(r['confidence'] for r in rows).items())),
    'reuse': dict(sorted(Counter(r['audit_reuse'] for r in rows).items())),
    'raw_balance_or_cap': sum(r['raw_balance_or_cap'] == 'true' for r in rows),
    'spike_or_deviation_check': sum(r['spike_or_deviation_check'] == 'true' for r in rows),
    'issuer_affiliate_asset': sum(r['issuer_affiliate_asset'] == 'true' for r in rows),
    'pinned_reproducer_value': sum(r['pinned_reproducer_value'] == 'true' for r in rows),
    'source_urls_unique': len({r['source'] for r in rows}),
    'note': 'Schema and reproduction-label validation only; not fork verification or a claim that every public incident is exhaustively enumerated.',
}
(ROOT / 'evidence').mkdir(exist_ok=True)
(ROOT / 'evidence/corpus-validation.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
