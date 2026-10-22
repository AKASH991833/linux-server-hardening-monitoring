#!/usr/bin/env python3
import json
from pathlib import Path
for r in json.loads(Path(__file__).with_name('cis-crosswalk.json').read_text()):
    print(f"{r['check']:8} {r['control'] or 'UNMAPPED':10} {r['coverage']}")
