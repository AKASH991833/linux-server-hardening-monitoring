#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
tests/make-fixtures.sh "$t/fx" >/dev/null
python3 - "$t" <<'END'
import json,sys
from pathlib import Path
t=Path(sys.argv[1]);json.dump(dict(hk_source=str(Path.cwd()),hk_install_dir=str(t/'install'),hk_target_root=str(t/'fx/insecure'),hk_state_dir=str(t/'state'),hk_apply=True,hk_fix_ids=['SSH-003','SSH-005','SSH-006','SSH-009','ACC-004','ACC-005','ACC-006']),open(t/'vars.json','w'))
END
ansible-playbook -i localhost, ansible/test.yml -e "@$t/vars.json" > "$t/first.log"
ansible-playbook -i localhost, ansible/test.yml -e "@$t/vars.json" > "$t/second.log"
cat "$t/first.log" "$t/second.log"
grep -q 'changed=0 ' "$t/second.log"
echo 'PASS: converge, verify, second run changed=0 (isolated rootfs, no daemon reload)'
