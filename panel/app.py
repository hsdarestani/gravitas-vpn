#!/usr/bin/env python3
import base64
import hmac
import json
import os
import re
import shutil
import sqlite3
import ssl
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

HOST = os.environ.get('PANEL_HOST', '0.0.0.0')
PORT = int(os.environ.get('PANEL_PORT', '9443'))
USERNAME = os.environ.get('PANEL_USER', 'admin')
PASSWORD_FILE = Path(os.environ.get('PANEL_PASSWORD_FILE', '/etc/gravitas-panel/admin_password'))
CERT_FILE = os.environ.get('PANEL_CERT_FILE', '/etc/gravitas-panel/tls.crt')
KEY_FILE = os.environ.get('PANEL_KEY_FILE', '/etc/gravitas-panel/tls.key')
DB_FILE = os.environ.get('PANEL_DB_FILE', '/var/lib/gravitas-panel/usage.db')
XRAY_BIN = os.environ.get('XRAY_BIN', '/usr/local/bin/xray')
XRAY_API = os.environ.get('XRAY_API', '127.0.0.1:10085')
USERS = [u.strip() for u in os.environ.get('GRAVITAS_USERS', 'hossein,kiarash,ahmad,ehsan,sajjad').split(',') if u.strip()]
POLL_SECONDS = int(os.environ.get('POLL_SECONDS', '30'))
ONLINE_WINDOW = int(os.environ.get('ONLINE_WINDOW', '180'))

PASSWORD = PASSWORD_FILE.read_text(encoding='utf-8').strip()
DB_LOCK = threading.Lock()
LAST_ERROR = ''
LAST_POLL = 0


def db():
    conn = sqlite3.connect(DB_FILE, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA synchronous=NORMAL')
    conn.execute('''CREATE TABLE IF NOT EXISTS state (
        user TEXT PRIMARY KEY,
        last_up INTEGER NOT NULL DEFAULT 0,
        last_down INTEGER NOT NULL DEFAULT 0,
        last_active INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS usage_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL,
        user TEXT NOT NULL,
        up INTEGER NOT NULL DEFAULT 0,
        down INTEGER NOT NULL DEFAULT 0
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_usage_user_ts ON usage_events(user, ts)')
    conn.commit()
    return conn


def run(cmd, timeout=8):
    return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout, check=False)


def xray_counters():
    proc = run([XRAY_BIN, 'api', 'statsquery', f'--server={XRAY_API}', '-pattern', 'user>>>'], timeout=10)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or 'xray statsquery failed').strip()[:500])
    try:
        payload = json.loads(proc.stdout or '{}')
    except json.JSONDecodeError as exc:
        raise RuntimeError(f'Could not parse Xray stats JSON: {exc}') from exc
    result = {u: {'up': 0, 'down': 0} for u in USERS}
    rx = re.compile(r'^user>>>(.+?)>>>traffic>>>(uplink|downlink)$')
    for item in payload.get('stat', []) or []:
        name = str(item.get('name', ''))
        match = rx.match(name)
        if not match:
            continue
        user, direction = match.groups()
        if user not in result:
            result[user] = {'up': 0, 'down': 0}
        try:
            value = int(item.get('value', 0))
        except (TypeError, ValueError):
            value = 0
        result[user]['up' if direction == 'uplink' else 'down'] = max(0, value)
    return result


def collect_once():
    global LAST_ERROR, LAST_POLL
    now = int(time.time())
    counters = xray_counters()
    with DB_LOCK:
        conn = db()
        try:
            for user in USERS:
                current = counters.get(user, {'up': 0, 'down': 0})
                row = conn.execute('SELECT * FROM state WHERE user=?', (user,)).fetchone()
                if row is None:
                    prev_up = prev_down = 0
                    last_active = 0
                else:
                    prev_up = int(row['last_up'])
                    prev_down = int(row['last_down'])
                    last_active = int(row['last_active'])

                cur_up = int(current.get('up', 0))
                cur_down = int(current.get('down', 0))
                delta_up = cur_up - prev_up if cur_up >= prev_up else cur_up
                delta_down = cur_down - prev_down if cur_down >= prev_down else cur_down
                delta_up = max(0, delta_up)
                delta_down = max(0, delta_down)
                if delta_up or delta_down:
                    conn.execute(
                        'INSERT INTO usage_events(ts,user,up,down) VALUES(?,?,?,?)',
                        (now, user, delta_up, delta_down),
                    )
                    last_active = now
                conn.execute('''
                    INSERT INTO state(user,last_up,last_down,last_active,updated_at)
                    VALUES(?,?,?,?,?)
                    ON CONFLICT(user) DO UPDATE SET
                      last_up=excluded.last_up,
                      last_down=excluded.last_down,
                      last_active=excluded.last_active,
                      updated_at=excluded.updated_at
                ''', (user, cur_up, cur_down, last_active, now))
            conn.commit()
        finally:
            conn.close()
    LAST_ERROR = ''
    LAST_POLL = now


def collector():
    global LAST_ERROR, LAST_POLL
    while True:
        try:
            collect_once()
        except Exception as exc:
            LAST_ERROR = str(exc)[:500]
            LAST_POLL = int(time.time())
        time.sleep(POLL_SECONDS)


def period_bounds(now):
    dt = datetime.fromtimestamp(now, tz=timezone.utc)
    day_start = int(datetime(dt.year, dt.month, dt.day, tzinfo=timezone.utc).timestamp())
    month_start = int(datetime(dt.year, dt.month, 1, tzinfo=timezone.utc).timestamp())
    return day_start, month_start


def service_active(name):
    p = run(['systemctl', 'is-active', name], timeout=3)
    return p.returncode == 0 and p.stdout.strip() == 'active'


def system_metrics():
    load = [0.0, 0.0, 0.0]
    try:
        load = [float(x) for x in Path('/proc/loadavg').read_text().split()[:3]]
    except Exception:
        pass
    mem_total = mem_available = 0
    try:
        mem = {}
        for line in Path('/proc/meminfo').read_text().splitlines():
            k, v = line.split(':', 1)
            mem[k] = int(v.strip().split()[0]) * 1024
        mem_total = mem.get('MemTotal', 0)
        mem_available = mem.get('MemAvailable', 0)
    except Exception:
        pass
    disk = shutil.disk_usage('/')
    uptime = 0
    try:
        uptime = int(float(Path('/proc/uptime').read_text().split()[0]))
    except Exception:
        pass
    return {
        'xray_active': service_active('xray'),
        'panel_active': True,
        'load': load,
        'memory_total': mem_total,
        'memory_used': max(0, mem_total - mem_available),
        'disk_total': disk.total,
        'disk_used': disk.used,
        'uptime': uptime,
    }


def snapshot():
    now = int(time.time())
    day_start, month_start = period_bounds(now)
    rows = []
    with DB_LOCK:
        conn = db()
        try:
            for user in USERS:
                st = conn.execute('SELECT * FROM state WHERE user=?', (user,)).fetchone()
                def sums(since=None):
                    if since is None:
                        r = conn.execute('SELECT COALESCE(SUM(up),0) up, COALESCE(SUM(down),0) down FROM usage_events WHERE user=?', (user,)).fetchone()
                    else:
                        r = conn.execute('SELECT COALESCE(SUM(up),0) up, COALESCE(SUM(down),0) down FROM usage_events WHERE user=? AND ts>=?', (user, since)).fetchone()
                    return int(r['up']), int(r['down'])
                today_up, today_down = sums(day_start)
                month_up, month_down = sums(month_start)
                total_up, total_down = sums(None)
                last_active = int(st['last_active']) if st else 0
                rows.append({
                    'user': user,
                    'online': bool(last_active and now - last_active <= ONLINE_WINDOW),
                    'last_active': last_active,
                    'today_up': today_up,
                    'today_down': today_down,
                    'month_up': month_up,
                    'month_down': month_down,
                    'total_up': total_up,
                    'total_down': total_down,
                })
        finally:
            conn.close()
    total_today = sum(r['today_up'] + r['today_down'] for r in rows)
    total_month = sum(r['month_up'] + r['month_down'] for r in rows)
    total_all = sum(r['total_up'] + r['total_down'] for r in rows)
    return {
        'now': now,
        'last_poll': LAST_POLL,
        'collector_error': LAST_ERROR,
        'online_window': ONLINE_WINDOW,
        'period_timezone': 'UTC',
        'totals': {'today': total_today, 'month': total_month, 'all': total_all},
        'users': rows,
        'system': system_metrics(),
    }


HTML = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Gravitas VPN</title>
<style>
:root{color-scheme:dark;--bg:#0b0d10;--panel:#11151a;--line:#242a32;--muted:#8e99a8;--text:#f4f6f8;--good:#65d29b}
*{box-sizing:border-box}body{margin:0;font-family:Inter,ui-sans-serif,system-ui,-apple-system,Segoe UI,sans-serif;background:var(--bg);color:var(--text)}
.wrap{max-width:1160px;margin:auto;padding:28px 18px 48px}.top{display:flex;align-items:flex-end;justify-content:space-between;gap:20px;margin-bottom:24px}
h1{font-size:26px;margin:0 0 6px}.sub{color:var(--muted);font-size:13px}.badge{border:1px solid var(--line);border-radius:999px;padding:7px 11px;font-size:12px;background:var(--panel)}
.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:18px}.card{background:var(--panel);border:1px solid var(--line);border-radius:15px;padding:16px}.k{font-size:12px;color:var(--muted);margin-bottom:7px}.v{font-size:22px;font-weight:700}.small{font-size:12px;color:var(--muted);margin-top:5px}
.table{overflow:auto;border:1px solid var(--line);border-radius:15px;background:var(--panel)}table{width:100%;border-collapse:collapse;min-width:850px}th,td{text-align:left;padding:14px 15px;border-bottom:1px solid var(--line);font-size:13px}th{color:var(--muted);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.06em}tr:last-child td{border-bottom:0}.person{font-weight:700}.status{display:inline-flex;align-items:center;gap:7px}.dot{width:8px;height:8px;border-radius:50%;background:#58616e}.dot.on{background:var(--good);box-shadow:0 0 0 4px rgba(101,210,155,.09)}
.sys{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-top:18px}.bar{height:7px;background:#20262d;border-radius:99px;overflow:hidden;margin-top:10px}.fill{height:100%;background:#a7b0bd}.err{display:none;border:1px solid #6f4d27;background:#22180d;color:#ffd99a;padding:12px 14px;border-radius:12px;margin:0 0 16px;font-size:13px}
@media(max-width:800px){.grid,.sys{grid-template-columns:repeat(2,minmax(0,1fr))}.top{align-items:flex-start;flex-direction:column}}@media(max-width:480px){.grid,.sys{grid-template-columns:1fr}}
</style></head><body><div class="wrap">
<div class="top"><div><h1>Gravitas VPN</h1><div class="sub">Xray / VLESS / REALITY · Traffic dashboard</div></div><div class="badge" id="updated">Loading…</div></div>
<div class="err" id="err"></div>
<div class="grid"><div class="card"><div class="k">Traffic today</div><div class="v" id="today">—</div><div class="small">UTC day</div></div><div class="card"><div class="k">This month</div><div class="v" id="month">—</div><div class="small">UTC month</div></div><div class="card"><div class="k">Tracked total</div><div class="v" id="total">—</div><div class="small">Since dashboard enabled</div></div><div class="card"><div class="k">Users active recently</div><div class="v" id="online">—</div><div class="small">Traffic seen in last 3 minutes</div></div></div>
<div class="table"><table><thead><tr><th>User</th><th>Status</th><th>Today</th><th>This month</th><th>Tracked total</th><th>Last activity</th></tr></thead><tbody id="users"></tbody></table></div>
<div class="sys"><div class="card"><div class="k">Xray</div><div class="v" id="xray">—</div></div><div class="card"><div class="k">CPU load (1m)</div><div class="v" id="load">—</div></div><div class="card"><div class="k">Memory</div><div class="v" id="mem">—</div><div class="bar"><div class="fill" id="membar"></div></div></div><div class="card"><div class="k">Disk</div><div class="v" id="disk">—</div><div class="bar"><div class="fill" id="diskbar"></div></div></div></div>
</div><script>
function bytes(n){n=Number(n||0);const u=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<u.length-1){n/=1024;i++}return (i? n.toFixed(n>=100?0:n>=10?1:2):Math.round(n))+' '+u[i]}
function ago(ts){if(!ts)return 'Never';let s=Math.max(0,Math.floor(Date.now()/1000-ts));if(s<60)return s+'s ago';if(s<3600)return Math.floor(s/60)+'m ago';if(s<86400)return Math.floor(s/3600)+'h ago';return Math.floor(s/86400)+'d ago'}
function pct(a,b){return b?Math.min(100,Math.round(a/b*100)):0}
async function refresh(){try{let r=await fetch('/api/data',{cache:'no-store'});if(!r.ok)throw new Error('HTTP '+r.status);let d=await r.json();
document.getElementById('today').textContent=bytes(d.totals.today);document.getElementById('month').textContent=bytes(d.totals.month);document.getElementById('total').textContent=bytes(d.totals.all);document.getElementById('online').textContent=d.users.filter(x=>x.online).length+' / '+d.users.length;
document.getElementById('users').innerHTML=d.users.map(x=>`<tr><td class="person">${x.user}</td><td><span class="status"><span class="dot ${x.online?'on':''}"></span>${x.online?'Active':'Idle'}</span></td><td>${bytes(x.today_up+x.today_down)}<div class="small">↑ ${bytes(x.today_up)} · ↓ ${bytes(x.today_down)}</div></td><td>${bytes(x.month_up+x.month_down)}</td><td>${bytes(x.total_up+x.total_down)}</td><td>${ago(x.last_active)}</td></tr>`).join('');
document.getElementById('xray').textContent=d.system.xray_active?'Online':'Down';document.getElementById('load').textContent=Number(d.system.load[0]).toFixed(2);let mp=pct(d.system.memory_used,d.system.memory_total),dp=pct(d.system.disk_used,d.system.disk_total);document.getElementById('mem').textContent=mp+'%';document.getElementById('disk').textContent=dp+'%';document.getElementById('membar').style.width=mp+'%';document.getElementById('diskbar').style.width=dp+'%';document.getElementById('updated').textContent='Updated '+new Date((d.last_poll||d.now)*1000).toLocaleTimeString();let e=document.getElementById('err');if(d.collector_error){e.style.display='block';e.textContent='Stats collector: '+d.collector_error}else e.style.display='none';
}catch(e){let el=document.getElementById('err');el.style.display='block';el.textContent='Dashboard refresh failed: '+e.message}}
refresh();setInterval(refresh,15000);
</script></body></html>'''


class Handler(BaseHTTPRequestHandler):
    server_version = 'GravitasPanel/1.0'

    def log_message(self, fmt, *args):
        return

    def _headers(self, code, content_type):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store, max-age=0')
        self.send_header('Pragma', 'no-cache')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'")
        self.end_headers()

    def _authorized(self):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Basic '):
            return False
        try:
            decoded = base64.b64decode(auth[6:], validate=True).decode('utf-8')
            user, password = decoded.split(':', 1)
        except Exception:
            return False
        return hmac.compare_digest(user, USERNAME) and hmac.compare_digest(password, PASSWORD)

    def do_GET(self):
        if not self._authorized():
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="Gravitas VPN"')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            return
        path = urlparse(self.path).path
        if path == '/api/data':
            data = json.dumps(snapshot(), separators=(',', ':')).encode('utf-8')
            self._headers(200, 'application/json; charset=utf-8')
            self.wfile.write(data)
            return
        if path in ('/', '/index.html'):
            body = HTML.encode('utf-8')
            self._headers(200, 'text/html; charset=utf-8')
            self.wfile.write(body)
            return
        self._headers(404, 'text/plain; charset=utf-8')
        self.wfile.write(b'Not found')


if __name__ == '__main__':
    Path(DB_FILE).parent.mkdir(parents=True, exist_ok=True)
    with DB_LOCK:
        conn = db()
        conn.close()
    try:
        collect_once()
    except Exception as exc:
        LAST_ERROR = str(exc)[:500]
        LAST_POLL = int(time.time())
    threading.Thread(target=collector, daemon=True, name='stats-collector').start()
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(CERT_FILE, KEY_FILE)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()
