#!/usr/bin/env bash
# Self-contained test-suite (no root needed, no dependencies except bash + coreutils).
#   tests/run.sh          run everything
set -uo pipefail
cd "$(dirname "$0")/.."
export NO_COLOR=1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HK_STATE="$T/state"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \e[32mok\e[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \e[31mFAIL\e[0m %s\n' "$1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }

tests/make-fixtures.sh "$T/fx" >/dev/null
I="$T/fx/insecure"; H="$T/fx/hardened"
snapshot() { (cd "$1" && find . -printf '%p %m %u\n' | sort; find . -type f -exec sha256sum {} + | sort); }

echo "== audit"
./hk audit --root "$H" --format json > "$T/h.json"; ./hk audit --root "$I" --format json > "$T/i.json"
assert "hardened fixture scores 100"            'grep -q "\"score\": 100" "$T/h.json"'
assert "insecure fixture scores below 30"       '[[ $(grep -o "\"score\": [0-9]*" "$T/i.json" | grep -o "[0-9]*$") -lt 30 ]]'
assert "JSON output is valid"                   'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$T/i.json"'
assert "detects extra UID-0 account"            'grep -q "extra UID-0 accounts: toor" "$T/i.json"'
assert "SSH first-match + Match block handled"  './hk audit --root "$I" --only SSH-002 | grep -q "PasswordAuthentication = yes"'
assert "detects SUID file in /tmp"              './hk audit --root "$I" --only FS-004 | grep -q /tmp/rootshell'
assert "--min-score exits non-zero when low"    '! ./hk audit --root "$I" --min-score 90 >/dev/null'
assert "--min-score exits 0 when high"          './hk audit --root "$H" --min-score 90 >/dev/null'
./hk audit --root "$I" --format all --out "$T/rep" >/dev/null
assert "HTML report written and self-contained" 'grep -q "<svg" "$T/rep/report.html" && ! grep -q "http://\|https://" "$T/rep/report.html"'

echo "== fix (dry-run, apply, anti-lockout, rollback)"
before=$(snapshot "$I")
./hk fix --root "$I" --all >/dev/null 2>&1
assert "dry-run changes nothing"                '[[ "$before" == "$(snapshot "$I")" ]]'
assert "anti-lockout refuses SSH-002 without keys" './hk fix --root "$I" SSH-002 | grep -q "REFUSED (anti-lockout)"'
./hk fix --apply --root "$I" --all >"$T/apply.log" 2>&1
./hk audit --root "$I" --format json > "$T/i2.json"
s2=$(grep -o '"score": [0-9]*' "$T/i2.json" | grep -o '[0-9]*$')
assert "apply raises the score (now $s2)"       '(( s2 > 60 ))'
assert "vendor sshd_config untouched (drop-in used)" 'grep -q "^PermitRootLogin yes" "$I/etc/ssh/sshd_config"'
assert "drop-in wins (SSH-001 now passes)"      './hk audit --root "$I" --only SSH-001 | grep -q "\[PASS\]"'
assert "world-writable shadow fixed to 640"     '[[ $(stat -c %a "$I/etc/shadow") == 640 ]]'
assert "SUID removed from /tmp/rootshell"       '[[ $(stat -c %a "$I/tmp/rootshell") == 755 ]]'
assert "empty password locked"                  'grep -q "^toor:!" "$I/etc/shadow"'
TX=$(ls "$HK_STATE/tx" | head -1)
./hk rollback "$TX" >/dev/null 2>&1
assert "rollback restores files/modes/content exactly" '[[ "$before" == "$(snapshot "$I")" ]]'
# with a key present, SSH-002 is allowed
mkdir -p "$I/home/alice/.ssh"; echo "ssh-ed25519 AAAA test" > "$I/home/alice/.ssh/authorized_keys"
./hk fix --apply --root "$I" SSH-002 >/dev/null 2>&1
assert "SSH-002 applies when a user has a key"  './hk audit --root "$I" --only SSH-002 | grep -q "\[PASS\]"'

echo "== drift"
./hk baseline create --root "$H" >/dev/null
assert "no drift right after baseline"          './hk drift --root "$H" >/dev/null'
echo "ssh-rsa BACKDOOR" >> "$H/home/alice/.ssh/authorized_keys"
touch "$H/usr/bin/newtool"; chmod 4755 "$H/usr/bin/newtool"
echo 'eve:x:1002:1002::/home/eve:/bin/bash' >> "$H/etc/passwd"
out=$(./hk drift --root "$H"); rc=$?
assert "drift exit code is 1"                   '(( rc == 1 ))'
assert "detects changed authorized_keys"        'grep -q "CHANGED.*authorized_keys" <<<"$out"'
assert "detects new SUID binary"                'grep -q "ADDED.*suid.*newtool" <<<"$out"'
assert "detects new login user"                 'grep -q "ADDED.*user.*eve" <<<"$out"'

echo "== monitor"
export HK_ALERT_CHANNELS=log HK_CONSECUTIVE=2 HK_AUTH_LOG="$T/auth.log"
now=$(date -u +%FT%T+00:00)
for i in $(seq 1 30); do echo "$now host sshd[1]: Failed password for root from 203.0.113.9 port 22 ssh2"; done > "$T/auth.log"
for i in 1 2 3; do echo "$now host sshd[1]: Invalid user admin from 198.51.100.7 port 22"; done >> "$T/auth.log"
./hk monitor once --simulate "mem=97,disk:/=50" >/dev/null
assert "first breach does NOT alert (flap suppression)" '[[ ! -s "$HK_STATE/alerts.log" ]] || ! grep -q "mem" "$HK_STATE/alerts.log"'
./hk monitor once --simulate "mem=97,disk:/=50" >/dev/null
assert "second consecutive breach alerts CRIT"  'grep -q "CRIT: mem = 97" "$HK_STATE/alerts.log"'
n1=$(grep -c "mem" "$HK_STATE/alerts.log"); ./hk monitor once --simulate "mem=98" >/dev/null
assert "no duplicate alert while still CRIT"    '[[ $(grep -c "mem" "$HK_STATE/alerts.log") == "$n1" ]]'
./hk monitor once --simulate "mem=40" >/dev/null
assert "RECOVERED notice when back to normal"   'grep -q "RECOVERED" "$HK_STATE/alerts.log"'
mon_out=$(./hk monitor once --simulate "mem=1")
assert "brute-force detection (top attacker IP shown)" 'grep -q "203.0.113.9" <<<"$mon_out"'
assert "Prometheus textfile is written"         'grep -q "hk_metric{name=\"mem\"}" "$HK_STATE/hk.prom"'
assert "monitor exit code 2 on CRIT"            './hk monitor once --simulate "disk:/=99" >/dev/null; [[ $? == 2 ]]'
unit=$(./hk monitor install --systemd)
assert "systemd timer unit is generated"        'grep -q "OnUnitActiveSec=1min" <<<"$unit"'


echo "== alert channels (mock webhook, telegram, mail servers)"
cat > "$T/mockhttp.py" <<'PY'
import http.server, sys
hits = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with open(hits, 'a') as f: f.write(self.path + ' ' + body.decode() + '\n')
        self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
: > "$T/hits"
python3 "$T/mockhttp.py" "$T/hits" > "$T/port" 2>"$T/mock.err" &
MOCKPID=$!
for _ in $(seq 1 25); do [[ -s $T/port ]] && break; sleep 0.2; done
PORT=$(cat "$T/port" 2>/dev/null || true)
if [[ -n $PORT ]]; then
  export HK_CONSECUTIVE=1
  rm -f "$HK_STATE/monitor.state"
  HK_ALERT_CHANNELS=webhook HK_WEBHOOK_URL="http://127.0.0.1:$PORT/hook" ./hk monitor once --simulate "mem=99" >/dev/null
  assert "webhook channel POSTs JSON to the configured URL" 'grep -q "^/hook {\"text\":" "$T/hits"'
  assert "webhook JSON carries level CRIT"                  'grep -q "\"level\":\"CRIT\"" "$T/hits"'
  echo "TESTTOKEN123" > "$T/tok"
  rm -f "$HK_STATE/monitor.state"
  HK_ALERT_CHANNELS=telegram HK_TELEGRAM_API="http://127.0.0.1:$PORT" HK_TELEGRAM_TOKEN_FILE="$T/tok" HK_TELEGRAM_CHAT=4242 ./hk monitor once --simulate "mem=99" >/dev/null
  assert "telegram channel calls bot API with the token"    'grep -q "/botTESTTOKEN123/sendMessage" "$T/hits"'
  assert "telegram payload carries chat_id and text"        'grep -q "chat_id=4242" "$T/hits"'
  kill $MOCKPID 2>/dev/null
else
  echo "  skip webhook/telegram mocks (no python3 http.server here; CI runs them)"
fi
mkdir -p "$T/bin"; printf '#!/bin/sh\ncat >> "%s/mailout"\n' "$T" > "$T/bin/mail"; chmod +x "$T/bin/mail"
rm -f "$HK_STATE/monitor.state"
PATH="$T/bin:$PATH" HK_ALERT_CHANNELS=mail HK_MAIL_TO=root@lab ./hk monitor once --simulate "mem=99" >/dev/null
assert "mail channel pipes the alert to mail(1)"            'grep -q "CRIT: mem = 99" "$T/mailout"'

echo; echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
