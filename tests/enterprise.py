#!/usr/bin/env python3
import json,re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
ids=set()
for f in (root/'checks').glob('*.sh'):ids.update(re.findall(r'^register (\S+)',f.read_text(),re.M))
rows=json.loads((root/'compliance/cis-crosswalk.json').read_text())
assert len(rows)==len(ids) and {r['check'] for r in rows}==ids
for r in rows:
    if r['control']: assert r['source'].startswith('https://') and r['page'].isdigit() and r['coverage'].startswith(('partial:','related:'))
dash=json.loads((root/'monitoring/grafana/dashboards/hk.json').read_text())
assert len(dash['panels'])==6 and len({p['id'] for p in dash['panels']})==6
print(f'PASS: {len(ids)} checks accounted for, no invented default mapping; six dashboard panels')
