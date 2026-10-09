#!/usr/bin/env python3
"""Single-process IPv4-only whitelist API. Python 3.9+; stdlib only."""
import hmac, http.server, ipaddress, json, logging, os, pathlib, subprocess, tempfile, threading

CFG = pathlib.Path('/etc/po0-dynamic-whitelist/config.json')
DATA = pathlib.Path('/var/lib/po0-dynamic-whitelist/whitelist.json')
SET = 'po0_dynamic_whitelist'
CHAIN = 'PO0_REGION_WHITELIST'
LOCK = threading.RLock()

def command(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout

def ipv4(s, public=False):
    ip = ipaddress.ip_address(s)
    if ip.version != 4 or (public and not ip.is_global):
        raise ValueError('public IPv4 required')
    return str(ip)

def read_config():
    c = json.loads(CFG.read_text())
    c['listen_host'] = ipv4(c['listen_host'])
    c['trusted_proxy_ip'] = ipv4(c['trusted_proxy_ip'])
    assert isinstance(c['max_slots'], int) and not isinstance(c['max_slots'], bool) and 1 <= c['max_slots'] <= 100
    assert isinstance(c['api_token'], str) and len(c['api_token']) >= 24
    assert 1 <= int(c['listen_port']) <= 65535
    return c

def read_queue():
    if not DATA.exists():
        return []
    v = json.loads(DATA.read_text())
    if not isinstance(v, list) or len(v) != len(set(v)):
        raise ValueError('invalid queue')
    return [ipv4(x, public=True) for x in v]

def save_queue(v):
    DATA.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, path = tempfile.mkstemp(prefix='.queue-', dir=str(DATA.parent))
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(v, f, separators=(',', ':'))
            f.flush(); os.fsync(f.fileno())
        os.chmod(path, 0o600)
        os.replace(path, DATA)
    finally:
        if os.path.exists(path): os.unlink(path)

def set_members():
    out = command('ipset', 'list', SET)
    return set(line.strip().removesuffix('/32') for line in out.split('Members:\n', 1)[1].splitlines() if line.strip())

def verify_rules():
    rules = command('iptables-nft', '-S', CHAIN).splitlines()
    dyn = [i for i, s in enumerate(rules) if '--match-set '+SET+' src' in s and '-j ACCEPT' in s]
    region = [i for i, s in enumerate(rules) if '--match-set po0_region_whitelist src' in s]
    reject = [i for i, s in enumerate(rules) if '-j REJECT' in s]
    return len(dyn)==1 and len(region)==1 and len(reject)==1 and dyn[0]<region[0]<reject[0]

def reconcile(queue):
    actual = set_members(); target = set(queue)
    # Add first to avoid interrupting whitelisted IPs.
    for ip in sorted(target-actual): command('ipset','add',SET,ip,'-exist')
    for ip in sorted(actual-target): command('ipset','del',SET,ip)

def forward_ready():
    try:
        command('bash', '/opt/po0-dynamic-whitelist/firewall.sh', 'verify')
        return True
    except Exception:
        return False

def snapshot(c, current_ip=None, action=None, evicted=None):
    q = read_queue()
    actual = set_members()
    return {'enabled': verify_rules() and forward_ready() and set(q)==actual,
            'whitelist':[{'ip':p, 'slot':None} for p in q],
            'limit':c['max_slots'], 'currentIp':current_ip or '',
            'action':action, 'evicted':evicted, 'firewall':{'input':verify_rules(), 'forward':forward_ready()}}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): logging.info('%s '+fmt, self.client_address[0], *args)
    def respond(self, code, data):
        b=json.dumps(data,ensure_ascii=False).encode()
        self.send_response(code); self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Cache-Control','no-store'); self.send_header('Content-Length',str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def auth(self):
        # Never trust an arbitrary X-Real-IP header from non-proxy peers.
        if self.client_address[0] != self.server.cfg['trusted_proxy_ip']:
            self.respond(403,{'error':'untrusted peer'}); return None
        token=self.headers.get('Authorization','')
        if not hmac.compare_digest(token,'Bearer '+self.server.cfg['api_token']):
            self.respond(401,{'error':'unauthorized'}); return None
        raw=self.headers.get('X-Real-IP','')
        try: return ipv4(raw,public=True)
        except ValueError:
            self.respond(400,{'error':'invalid public IPv4'}); return None
    def do_GET(self):
        if self.path != '/status': return self.respond(404,{'error':'not found'})
        ip=self.auth()
        if not ip:return
        try:
            with LOCK:self.respond(200,snapshot(self.server.cfg,ip))
        except Exception:logging.exception('status failed');self.respond(503,{'error':'firewall unavailable'})
    def do_POST(self):
        if self.path != '/add':return self.respond(404,{'error':'not found'})
        ip=self.auth()
        if not ip:return
        try:
            with LOCK:
                if not verify_rules() or not forward_ready():return self.respond(503,{'error':'INPUT/FORWARD guard not verified'})
                old=read_queue()
                if set(old)!=set_members():return self.respond(503,{'error':'queue / ipset mismatch; manual repair required'})
                if ip in old:
                    return self.respond(200,snapshot(self.server.cfg,ip,'exists'))
                new=list(old);new.append(ip)
                evicted=new.pop(0) if len(new)>self.server.cfg['max_slots'] else None
                try:
                    reconcile(new)
                    save_queue(new)
                except Exception:
                    logging.exception('add failed; restoring previous ipset')
                    try: reconcile(old)
                    except Exception:logging.exception('restore failed')
                    return self.respond(503,{'error':'failed to apply whitelist'})
                self.respond(200,snapshot(self.server.cfg,ip,'evicted' if evicted else 'added',evicted))
        except Exception:logging.exception('add failed');self.respond(503,{'error':'firewall unavailable'})
    def do_DELETE(self):self.respond(405,{'error':'method not allowed'})

if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    c=read_config()
    with LOCK:
        q=read_queue()
        if len(q)>c['max_slots']:
            raise SystemExit('queue exceeds max_slots; adjust config before start')
        if not verify_rules():raise SystemExit('dynamic firewall rule is not active')
        reconcile(q)
    srv=http.server.ThreadingHTTPServer((c['listen_host'],int(c['listen_port'])),Handler)
    srv.cfg=c
    srv.serve_forever()
