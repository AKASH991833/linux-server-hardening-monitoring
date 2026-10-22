#!/usr/bin/env python3
"""Read-only metrics endpoint. No commands or parameters accepted from HTTP."""
import os, subprocess, time, threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
HOME = Path(__file__).resolve().parents[1]
STATE = Path(os.environ.get('HK_STATE', '/tmp/hk-state'))
CACHE = b''
LOCK = threading.Lock()
def collect():
    global CACHE
    start=time.monotonic()
    try:
        subprocess.run([str(HOME/'hk'),'monitor','once'],capture_output=True,timeout=25,check=False)
        text=(STATE/'hk.prom').read_text()
        payload=(text+'\n# TYPE hk_exporter_success gauge\nhk_exporter_success 1\n# TYPE hk_collection_timestamp_seconds gauge\nhk_collection_timestamp_seconds '+str(time.time())+'\n# TYPE hk_collection_duration_seconds gauge\nhk_collection_duration_seconds '+str(time.monotonic()-start)+'\n').encode()
    except (OSError,subprocess.TimeoutExpired):
        payload=b'# TYPE hk_exporter_success gauge\nhk_exporter_success 0\n'
    with LOCK: CACHE=payload
    return payload
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/metrics':
            self.send_error(404);return
        with LOCK: payload=CACHE
        self.send_response(200);self.send_header('Content-Type','text/plain; version=0.0.4');self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
    def log_message(self,*args): pass
def loop():
    while True:
        collect();time.sleep(30)
if __name__=='__main__':
    STATE.mkdir(parents=True,exist_ok=True)
    collect();threading.Thread(target=loop,daemon=True).start()
    ThreadingHTTPServer((os.environ.get('HK_EXPORTER_BIND','0.0.0.0'),9108),Handler).serve_forever()
