#!/usr/bin/env python3
"""
Claude Monitor — standalone server
Works on macOS and Linux (any Python 3.8+, zero dependencies).

Usage:
    python3 claude-monitor-server.py          # port 7337
    python3 claude-monitor-server.py 8080     # custom port
    python3 claude-monitor-server.py --open   # open browser on start
    python3 claude-monitor-server.py --install # install as daemon

Open http://localhost:<port> in your browser.
For remote VMs: ssh -L 7337:localhost:7337 user@host  then open localhost:7337
"""

import argparse
import glob
import http.server
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import webbrowser

_parser = argparse.ArgumentParser(description='Claude Monitor Server')
_parser.add_argument('port', nargs='?', type=int, default=7337, help='Port to listen on')
_parser.add_argument('--open', action='store_true', help='Open browser after server starts')
_parser.add_argument('--install', action='store_true', help='Install as system daemon')
_args = _parser.parse_args()
PORT = _args.port
IS_LINUX = platform.system() == 'Linux'

# ── Paths ──────────────────────────────────────────────────────────────────────
HOME          = os.path.expanduser('~')
CLAUDE_DIR    = os.path.join(HOME, '.claude')
PROJECTS_DIR  = os.path.join(CLAUDE_DIR, 'projects')
TEAMS_DIR     = os.path.join(CLAUDE_DIR, 'teams')
TASKS_DIR     = os.path.join(CLAUDE_DIR, 'tasks')
SESSION_NAMES = os.path.join(CLAUDE_DIR, 'session-names.json')
DATA_FILE     = '/tmp/claude-monitor-data.json'

UUID_RE = re.compile(r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}')

# ── Pricing & context windows ──────────────────────────────────────────────────
CONTEXT_WINDOWS = {
    'claude-opus-4':   200000,
    'claude-sonnet-4': 200000,
    'claude-haiku-4':  200000,
}
PRICING = {
    'claude-opus-4-6':   {'input': 15.0,  'output': 75.0,  'cache_read': 1.5,  'cache_write': 18.75},
    'claude-sonnet-4-6': {'input': 3.0,   'output': 15.0,  'cache_read': 0.3,  'cache_write': 3.75},
    'claude-haiku-4-5':  {'input': 0.8,   'output': 4.0,   'cache_read': 0.08, 'cache_write': 1.0},
}
DEFAULT_CONTEXT = 200000


def get_context_window(model):
    for prefix, size in CONTEXT_WINDOWS.items():
        if model.startswith(prefix):
            return size
    return DEFAULT_CONTEXT


def calc_cost(model, input_tok, output_tok, cache_read=0, cache_write=0):
    p = None
    for name, pricing in PRICING.items():
        if name in model or model in name:
            p = pricing
            break
    if not p:
        p = PRICING['claude-sonnet-4-6']
    return (
        input_tok  * p['input']       / 1e6 +
        output_tok * p['output']      / 1e6 +
        cache_read * p['cache_read']  / 1e6 +
        cache_write * p['cache_write'] / 1e6
    )

# ── Shared data (collector → server) ──────────────────────────────────────────
_data_lock = threading.Lock()
_current_data = {'timestamp': '', 'processes': [], 'agents': [], 'sessionNames': {}, 'system': {}}

_proc_order = {}  # pid -> first_seen float
_proc_order_lock = threading.Lock()

# ── Activity state (in-memory JSONL tail) ──────────────────────────────────────
_activity_lock = threading.Lock()
_activity_state = {}  # jsonl_path -> state dict

TOOL_LABELS = {
    'Read':            lambda i: 'Reading '   + os.path.basename(i.get('file_path', '') or ''),
    'Edit':            lambda i: 'Editing '   + os.path.basename(i.get('file_path', '') or ''),
    'Write':           lambda i: 'Writing '   + os.path.basename(i.get('file_path', '') or ''),
    'Bash':            lambda i: 'Running: '  + (i.get('command', '') or '')[:40],
    'Glob':            lambda _: 'Searching files',
    'Grep':            lambda _: 'Searching code',
    'WebFetch':        lambda _: 'Fetching web',
    'WebSearch':       lambda _: 'Searching web',
    'Task':            lambda i: 'Subtask: '  + (i.get('description', '') or '')[:30],
    'AskUserQuestion': lambda _: 'Waiting for answer',
    'EnterPlanMode':   lambda _: 'Planning',
    'NotebookEdit':    lambda _: 'Editing notebook',
    'SendMessage':     lambda i: 'Messaging ' + (i.get('to_agent_id', '') or ''),
    'TaskUpdate':      lambda _: 'Updating task',
    'TaskCreate':      lambda _: 'Creating task',
    'TaskList':        lambda _: 'Listing tasks',
    'TaskGet':         lambda _: 'Getting task',
}
PERMISSION_EXEMPT = {'Task', 'AskUserQuestion'}
DISSOLVE_KEYWORDS = [
    'fully dissolved', 'team is dissolved', 'has been dissolved',
    'shut down cleanly', 'all agents have shut', 'team dissolved',
    'team has completed', 'mission complete', 'all tasks completed',
    'team is fully',
]

TOOL_ICONS = {
    'Read': '📄', 'Edit': '✏️', 'Write': '💾', 'Bash': '⚡',
    'Glob': '🔍', 'Grep': '🔎', 'WebFetch': '🌐', 'WebSearch': '🌐',
    'Task': '🤖', 'AskUserQuestion': '❓', 'TodoWrite': '📋',
    'NotebookEdit': '📓', 'SendMessage': '✉️',
}


# ── Helpers ────────────────────────────────────────────────────────────────────

def load_session_names():
    """Returns {uuid: name} dict, supporting both old (name->uuid) and new (name->{id:uuid}) formats."""
    try:
        data = json.load(open(SESSION_NAMES))
        result = {}
        for k, v in data.items():
            if isinstance(v, dict) and 'id' in v:
                result[v['id']] = k
            elif isinstance(v, str):
                result[v] = k
        return result
    except:
        return {}


def load_session_names_raw():
    """Returns raw dict from session-names.json."""
    try:
        return json.load(open(SESSION_NAMES))
    except:
        return {}


def save_session_names(raw):
    try:
        with open(SESSION_NAMES, 'w') as f:
            json.dump(raw, f, indent=2)
        return True
    except:
        return False


def session_tokens_from_jsonl(path):
    """Returns last/cumulative token data from session jsonl."""
    last_input = last_output = last_cache_read = last_cache_write = 0
    model = ''
    cwd = ''
    try:
        with open(path) as f:
            for line in f:
                try:
                    d = json.loads(line)
                    if not cwd and d.get('cwd'):
                        cwd = d['cwd']
                    msg = d.get('message', {})
                    if not model and msg.get('model'):
                        model = msg['model']
                    usage = msg.get('usage', {})
                    if usage:
                        if usage.get('input_tokens'):
                            last_input = usage.get('input_tokens', 0)
                        if usage.get('output_tokens'):
                            last_output = usage.get('output_tokens', 0)
                        if usage.get('cache_creation_input_tokens'):
                            last_cache_write = usage.get('cache_creation_input_tokens', 0)
                        if usage.get('cache_read_input_tokens'):
                            last_cache_read = usage.get('cache_read_input_tokens', 0)
                except:
                    pass
    except:
        pass
    return model, cwd, last_input, last_output, last_cache_read, last_cache_write


def list_all_sessions(active_sessions, agents, name_by_id):
    sessions = []
    seen = set()
    for proj_dir in glob.glob(os.path.join(PROJECTS_DIR, '*')):
        for jf in glob.glob(os.path.join(proj_dir, '*.jsonl')):
            sid = os.path.splitext(os.path.basename(jf))[0]
            if sid in seen or not UUID_RE.match(sid):
                continue
            seen.add(sid)
            model, cwd, inp, out, cr, cw = session_tokens_from_jsonl(jf)
            ctx = get_context_window(model)
            ctx_used = inp + cr + cw  # input + cache_read + cache_write = real context
            ctx_pct = round(ctx_used / ctx * 100, 1) if ctx and ctx_used else 0
            cost = calc_cost(model, inp, out, cr, cw)
            is_active = sid in active_sessions
            agent_count = sum(1 for a in agents if a.get('sessionId') == sid)
            team_count = 0
            if os.path.isdir(TEAMS_DIR):
                for tname in os.listdir(TEAMS_DIR):
                    cfg_path = os.path.join(TEAMS_DIR, tname, 'config.json')
                    try:
                        cfg = json.load(open(cfg_path))
                        if cfg.get('leadSessionId') == sid:
                            team_count += 1
                    except:
                        pass
            sessions.append({
                'id': sid,
                'name': name_by_id.get(sid, ''),
                'model': model,
                'cwd': cwd,
                'is_active': is_active,
                'tokens': {
                    'input': inp, 'output': out,
                    'cache_read': cr, 'cache_write': cw,
                    'ctx_used': ctx_used,
                    'context_window': ctx,
                    'context_pct': ctx_pct,
                },
                'cost_usd': round(cost, 4),
                'agent_count': agent_count,
                'team_count': team_count,
            })
    sessions.sort(key=lambda s: (0 if s['is_active'] else 1, s['name'] or s['id']))
    return sessions


def get_ppid(pid):
    try:
        if IS_LINUX:
            return int(open(f'/proc/{pid}/status').read().split('PPid:')[1].split()[0])
        return int(subprocess.check_output(
            ['ps', '-o', 'ppid=', '-p', str(pid)], stderr=subprocess.DEVNULL
        ).decode().strip())
    except:
        return 0


def model_from_jsonl(session_id):
    matches = glob.glob(os.path.join(PROJECTS_DIR, '*', session_id + '.jsonl'))
    if not matches:
        return ''
    try:
        for line in open(matches[0]):
            try:
                m = json.loads(line).get('message', {}).get('model', '')
                if m:
                    return m
            except:
                pass
    except:
        pass
    return ''


def find_agent_outputs():
    """Find all .output files under /tmp/**/tasks/ — works on Linux and macOS."""
    paths = []
    search_roots = ['/tmp']
    if not IS_LINUX:
        search_roots.append('/private/tmp')
    for root in search_roots:
        try:
            for match in glob.glob(os.path.join(root, 'claude-*', '*', 'tasks', '*.output')):
                paths.append(match)
        except:
            pass
    return paths


def find_claude_processes():
    """Parse running Claude processes. Returns list of dicts."""
    try:
        out = subprocess.check_output(
            ['ps', 'aux'], stderr=subprocess.DEVNULL
        ).decode('utf-8', errors='replace')
    except:
        return []

    results = []
    for line in out.splitlines():
        if not re.search(r'(^|\s)claude(\s|$|/)', line):
            continue
        if any(x in line for x in ['grep', 'claude-monitor', 'claude-monitor-server']):
            continue
        parts = line.split(None, 10)
        if len(parts) < 11:
            continue
        try:
            pid  = int(parts[1])
            cpu  = float(parts[2])
            mem  = float(parts[3])
            vsz  = int(parts[4])
            rss  = int(parts[5])
            tty  = parts[6]
            stat = parts[7]
            started = parts[8]
            elapsed = parts[9]
            cmd  = parts[10].strip()
        except:
            continue

        # Skip shell wrappers
        if re.match(r'(zsh|bash|sh)\s', cmd):
            continue

        # Skip zombie/uninterruptible processes: Z state, or UE with tiny rss (<1MB)
        if 'Z' in stat or ('U' in stat and 'E' in stat and rss < 1000):
            continue

        # Skip --version / -v one-shot invocations
        if re.search(r'(\s|^)(-v|--version)(\s|$)', cmd):
            continue

        source = 'vscode' if 'vscode' in cmd else 'terminal'

        model = 'unknown'
        m = re.search(r'--model\s+([a-z0-9.\-]+)', cmd)
        if m:
            model = m.group(1)

        session_id = ''
        m2 = re.search(r'--(session-id|resume)\s+([a-f0-9-]{36})', cmd)
        if m2:
            session_id = m2.group(2)
        else:
            m3 = UUID_RE.search(cmd)
            if m3:
                session_id = m3.group(0)

        results.append({
            'pid': pid, 'cpu': cpu, 'mem': mem, 'vsz': vsz, 'rss': rss,
            'tty': tty, 'stat': stat, 'started': started, 'time': elapsed,
            'model': model, 'source': source, 'sessionId': session_id, 'cmd': cmd,
        })
    return results


# ── Collector loop ─────────────────────────────────────────────────────────────

def collect_once():
    name_by_id = load_session_names()
    procs_raw  = find_claude_processes()
    active_sessions = set()

    processes = []
    for p in procs_raw:
        sid = p['sessionId']
        p['ppid'] = get_ppid(p['pid'])
        p['sessionName'] = name_by_id.get(sid, '')
        if p['model'] == 'unknown' and sid:
            jm = model_from_jsonl(sid)
            if jm:
                p['model'] = jm
        if sid:
            active_sessions.add(sid)
        processes.append(p)

    now = time.time()

    # Stable process ordering: assign first_seen timestamp and sort by it
    with _proc_order_lock:
        current_pids = {p['pid'] for p in processes}
        for p in processes:
            if p['pid'] not in _proc_order:
                _proc_order[p['pid']] = now
            p['first_seen'] = _proc_order[p['pid']]
        # Clean up pids no longer present
        for pid in list(_proc_order.keys()):
            if pid not in current_pids:
                del _proc_order[pid]
    processes.sort(key=lambda p: p['first_seen'])
    agents = []
    for f in find_agent_outputs():
        if not os.path.isfile(f):
            continue
        agent_id = os.path.basename(f)[:-7]
        try:
            st   = os.stat(f)
            age  = int(now - st.st_mtime)
            size = st.st_size
            mtime = time.strftime('%H:%M:%S', time.localtime(st.st_mtime))
        except:
            continue

        session_id = model = cwd = last_line = ''
        input_tok = output_tok = 0
        try:
            for raw in open(f, errors='replace'):
                try:
                    d = json.loads(raw)
                    if not session_id and d.get('sessionId'):
                        session_id = d['sessionId']
                    if not cwd and d.get('cwd'):
                        cwd = d['cwd']
                    msg = d.get('message', {})
                    if not model and msg.get('model'):
                        model = msg['model']
                    usage = msg.get('usage', {})
                    if usage.get('output_tokens'):
                        input_tok  += usage.get('input_tokens', 0)
                        output_tok += usage.get('output_tokens', 0)
                    for c in msg.get('content', []):
                        if isinstance(c, dict) and c.get('type') == 'text' and c.get('text', '').strip():
                            last_line = c['text'].strip()[:120]
                    if d.get('type') == 'result' and d.get('result', '').strip():
                        last_line = d['result'].strip()[:120]
                except:
                    pass
        except:
            pass

        status = 'running' if (age < 10 and session_id and session_id in active_sessions) else 'completed'
        agents.append({
            'id': agent_id, 'sessionId': session_id,
            'sessionName': name_by_id.get(session_id, ''),
            'status': status, 'lastUpdate': mtime, 'size': size,
            'lastLine': last_line, 'model': model, 'cwd': cwd,
            'tokens': {'input': input_tok, 'output': output_tok},
        })

    # Deduplicate agents by id (macOS /tmp and /private/tmp are the same filesystem)
    seen_agent_ids = set()
    deduped = []
    for a in agents:
        if a['id'] not in seen_agent_ids:
            seen_agent_ids.add(a['id'])
            deduped.append(a)
    agents = deduped

    result = {
        'timestamp':    time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'processes':    processes,
        'agents':       agents,
        'sessionNames': name_by_id,
        'system':       {},
    }
    with _data_lock:
        _current_data.clear()
        _current_data.update(result)


def collector_loop():
    while True:
        try:
            collect_once()
        except Exception:
            pass
        # Adaptive: fast when Claude is running, slow when idle
        with _data_lock:
            has_procs = bool(_current_data.get('processes'))
        time.sleep(1 if has_procs else 5)


# ── Activity tracking ──────────────────────────────────────────────────────────

def _process_jsonl_line(st, line):
    line = line.strip()
    if not line:
        return
    try:
        d = json.loads(line)
    except:
        return

    rtype = d.get('type', '')
    st['last_record_type'] = rtype

    if rtype == 'assistant':
        content = d.get('message', {}).get('content', [])
        if isinstance(content, list):
            for block in content:
                if block.get('type') == 'tool_use':
                    tid   = block.get('id', '')
                    tname = block.get('name', '')
                    inp   = block.get('input', {}) or {}
                    fn    = TOOL_LABELS.get(tname)
                    label = fn(inp) if fn else ('Using ' + tname)
                    st['active_tools'][tid] = {'name': tname, 'label': label}
                    st['had_turn_duration'] = False
            for block in content:
                if block.get('type') == 'text':
                    txt = (block.get('text', '') or '').lower()
                    if any(k in txt for k in DISSOLVE_KEYWORDS):
                        st['dissolved']     = True
                        st['dissolve_msg']  = block.get('text', '')[:300]

    elif rtype == 'user':
        content = d.get('message', {}).get('content', [])
        if isinstance(content, list):
            if any(b.get('type') == 'tool_result' for b in content):
                for b in content:
                    if b.get('type') == 'tool_result':
                        st['active_tools'].pop(b.get('tool_use_id', ''), None)
            else:
                st['active_tools'].clear()
                st['had_turn_duration'] = False
                st['dissolved'] = False
        elif isinstance(content, str) and content.strip():
            st['active_tools'].clear()
            st['had_turn_duration'] = False

    elif rtype == 'system' and d.get('subtype') == 'turn_duration':
        st['active_tools'].clear()
        st['had_turn_duration'] = True


def refresh_activity(jsonl_path):
    with _activity_lock:
        if jsonl_path not in _activity_state:
            _activity_state[jsonl_path] = {
                'offset': 0, 'line_buf': '',
                'active_tools': {}, 'had_turn_duration': False,
                'last_record_type': None,
                'dissolved': False, 'dissolve_msg': '',
                'last_mtime': 0,
            }
        st = _activity_state[jsonl_path]
        try:
            info = os.stat(jsonl_path)
        except:
            return st
        size  = info.st_size
        mtime = info.st_mtime
        if size < st['offset']:
            st.update({'offset': 0, 'line_buf': '', 'active_tools': {},
                        'had_turn_duration': False, 'dissolved': False, 'dissolve_msg': ''})
        if size > st['offset']:
            try:
                with open(jsonl_path, 'rb') as f:
                    f.seek(st['offset'])
                    new_bytes = f.read(size - st['offset'])
                st['offset'] = size
                text  = st['line_buf'] + new_bytes.decode('utf-8', errors='replace')
                lines = text.split('\n')
                st['line_buf'] = lines.pop()
                for line in lines:
                    _process_jsonl_line(st, line)
            except:
                pass
        st['last_mtime'] = mtime
        return st


def state_to_result(st):
    age = time.time() - st.get('last_mtime', 0)
    if st.get('dissolved'):
        return {'status': 'dissolved', 'activity': 'Team dissolved', 'tool': '',
                'dissolved': True, 'dissolve_msg': st.get('dissolve_msg', '')}
    if st['active_tools']:
        chosen = next((t for t in st['active_tools'].values() if t['name'] not in PERMISSION_EXEMPT), None)
        chosen = chosen or next(iter(st['active_tools'].values()))
        return {'status': 'active', 'activity': chosen['label'], 'tool': chosen['name'],
                'dissolved': False, 'dissolve_msg': ''}
    # "Waiting for input" only when turn finished AND file has been idle for 5+ seconds
    # (if age < 5, claude is still processing/writing; active_tools already cleared means turn done)
    if st['had_turn_duration'] and 5 < age < 120:
        return {'status': 'waiting', 'activity': 'Waiting for input', 'tool': '',
                'dissolved': False, 'dissolve_msg': ''}
    return {'status': 'idle', 'activity': '', 'tool': '', 'dissolved': False, 'dissolve_msg': ''}


def find_jsonl(session_id, cwd_param=''):
    matches = glob.glob(os.path.join(PROJECTS_DIR, '*', session_id + '.jsonl'))
    if not matches and cwd_param:
        encoded   = cwd_param.replace('/', '-').lstrip('-')
        proj_dir  = os.path.join(PROJECTS_DIR, encoded)
        candidates = glob.glob(os.path.join(proj_dir, '*.jsonl'))
        if candidates:
            matches = [max(candidates, key=os.path.getmtime)]
    if not matches:
        all_jsonl = glob.glob(os.path.join(PROJECTS_DIR, '*', '*.jsonl'))
        if all_jsonl:
            matches = [max(all_jsonl, key=os.path.getmtime)]
    return matches[0] if matches else None


def auto_delete_team_for_jsonl(jsonl_path):
    if not os.path.isdir(TEAMS_DIR):
        return
    session_id = os.path.splitext(os.path.basename(jsonl_path))[0]
    for tname in os.listdir(TEAMS_DIR):
        cfg_path = os.path.join(TEAMS_DIR, tname, 'config.json')
        try:
            cfg = json.load(open(cfg_path))
            if cfg.get('leadSessionId') == session_id:
                shutil.rmtree(os.path.join(TEAMS_DIR, tname), ignore_errors=True)
                with _activity_lock:
                    _activity_state.pop(jsonl_path, None)
                break
        except:
            pass


def watcher_loop():
    while True:
        with _activity_lock:
            paths = list(_activity_state.keys())
        for p in paths:
            try:
                st = refresh_activity(p)
                if st.get('dissolved'):
                    auto_delete_team_for_jsonl(p)
            except:
                pass
        time.sleep(0.3)


# ── HTTP handler ───────────────────────────────────────────────────────────────

def _json_response(handler, obj, status=200):
    body = json.dumps(obj).encode()
    handler.send_response(status)
    handler.send_header('Content-Type', 'application/json')
    handler.send_header('Access-Control-Allow-Origin', '*')
    handler.send_header('Cache-Control', 'no-cache, no-store')
    handler.end_headers()
    handler.wfile.write(body)


def _read_messages_from_jsonl(path, last_n=10):
    messages = []
    try:
        with open(path) as f:
            for line in f:
                try:
                    d    = json.loads(line)
                    msg  = d.get('message', {})
                    role = msg.get('role', '')
                    if role not in ('user', 'assistant'):
                        continue
                    content = msg.get('content', '')
                    text    = ''
                    if isinstance(content, str):
                        text = content.strip()
                    elif isinstance(content, list):
                        parts = []
                        for c in content:
                            if not isinstance(c, dict):
                                continue
                            if c.get('type') == 'text' and c.get('text', '').strip():
                                parts.append(c['text'].strip())
                            elif c.get('type') == 'tool_use':
                                inp  = c.get('input', {}) or {}
                                name = c.get('name', '')
                                if name == 'Bash':
                                    parts.append('[Bash] ' + (inp.get('command', '') or '')[:80])
                                elif name in ('Read', 'Edit', 'Write'):
                                    parts.append(f'[{name}] ' + os.path.basename(inp.get('file_path', '') or ''))
                                elif name:
                                    parts.append(f'[{name}]')
                        text = ' '.join(parts).strip()
                    if text:
                        messages.append({'role': role, 'content': text})
                except:
                    pass
    except:
        pass
    return messages[-last_n:]


class MonitorHandler(http.server.BaseHTTPRequestHandler):

    def cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache, no-store')

    def do_OPTIONS(self):
        self.send_response(200)
        self.cors()
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path   = parsed.path
        params = urllib.parse.parse_qs(parsed.query)

        # ── Serve the HTML dashboard ──
        if path in ('/', '/index.html'):
            html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'claude-monitor.html')
            try:
                body = open(html_path, 'rb').read()
                # Rewrite localhost:7337 to the actual port if different
                if PORT != 7337:
                    body = body.replace(b'localhost:7337', f'localhost:{PORT}'.encode())
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                _json_response(self, {'error': str(e)}, 404)
            return

        # ── /data ──
        if path == '/data':
            with _data_lock:
                _json_response(self, dict(_current_data))
            return

        # ── /kill?pid=N ──
        if path == '/kill':
            pid_list = params.get('pid', [])
            if not pid_list:
                _json_response(self, {'error': 'Missing pid'}, 400)
                return
            try:
                pid = int(pid_list[0])
                os.kill(pid, signal.SIGTERM)
                _json_response(self, {'success': True, 'pid': pid})
            except ProcessLookupError:
                _json_response(self, {'success': False, 'error': 'Process not found'})
            except PermissionError:
                _json_response(self, {'success': False, 'error': 'Permission denied'})
            except Exception as e:
                _json_response(self, {'success': False, 'error': str(e)})
            return

        # ── /session/<id> ──
        if path.startswith('/session/'):
            session_id = path[len('/session/'):]
            cwd_param  = params.get('cwd', [''])[0]
            jsonl = find_jsonl(session_id, cwd_param)
            if not jsonl:
                _json_response(self, {'error': 'not found'}, 404)
                return
            _json_response(self, {'messages': _read_messages_from_jsonl(jsonl)})
            return

        # ── /agent/<id> ──
        if path.startswith('/agent/'):
            agent_id = path[len('/agent/'):]
            matches  = glob.glob(f'/tmp/claude-*/*/tasks/{agent_id}.output')
            if not IS_LINUX:
                matches += glob.glob(f'/private/tmp/claude-*/*/tasks/{agent_id}.output')
            if not matches:
                _json_response(self, {'error': 'not found'}, 404)
                return
            _json_response(self, {'messages': _read_messages_from_jsonl(matches[0])})
            return

        # ── /activity-bulk?ids=a,b,c ──
        if path == '/activity-bulk':
            ids    = [s.strip() for s in params.get('ids', [''])[0].split(',') if s.strip()]
            result = {}
            for sid in ids:
                try:
                    jp = find_jsonl(sid)
                    st = refresh_activity(jp) if jp else None
                    result[sid] = state_to_result(st) if st else {'status': 'idle', 'activity': '', 'tool': '', 'dissolved': False, 'dissolve_msg': ''}
                except:
                    result[sid] = {'status': 'idle', 'activity': '', 'tool': '', 'dissolved': False, 'dissolve_msg': ''}
            _json_response(self, result)
            return

        # ── /activity/<id> ──
        if path.startswith('/activity/'):
            session_id = path[len('/activity/'):]
            cwd_param  = params.get('cwd', [''])[0]
            jp = find_jsonl(session_id, cwd_param)
            st = refresh_activity(jp) if jp else None
            _json_response(self, state_to_result(st) if st else {'status': 'idle', 'activity': '', 'tool': '', 'dissolved': False, 'dissolve_msg': ''})
            return

        # ── /teams ──
        if path == '/teams':
            result = []
            if not os.path.isdir(TEAMS_DIR):
                _json_response(self, {'teams': []})
                return
            try:
                for tname in sorted(os.listdir(TEAMS_DIR)):
                    cfg_path = os.path.join(TEAMS_DIR, tname, 'config.json')
                    if not os.path.exists(cfg_path):
                        continue
                    try:
                        cfg = json.load(open(cfg_path))
                    except:
                        continue

                    lead_session_id = cfg.get('leadSessionId', '')
                    lead_jsonl = find_jsonl(lead_session_id) if lead_session_id else None
                    if lead_jsonl:
                        lead_st = refresh_activity(lead_jsonl)
                        if lead_st.get('dissolved'):
                            auto_delete_team_for_jsonl(lead_jsonl)
                            continue

                    members_cfg = {m['name']: m for m in cfg.get('members', [])}

                    # Tasks
                    tasks = []
                    tasks_path = os.path.join(TASKS_DIR, tname)
                    if os.path.isdir(tasks_path):
                        for tf in sorted(os.listdir(tasks_path)):
                            if tf.endswith('.json'):
                                try:
                                    t = json.load(open(os.path.join(tasks_path, tf)))
                                    if not t.get('metadata', {}).get('_internal'):
                                        tasks.append(t)
                                except:
                                    pass

                    # Subagent JSONL mapping
                    member_subagent = {}
                    subagent_model  = {}
                    subagent_session = {}
                    subagents_dir   = None
                    for proj_dir in glob.glob(os.path.join(PROJECTS_DIR, '*')):
                        candidate = os.path.join(proj_dir, lead_session_id, 'subagents')
                        if os.path.isdir(candidate):
                            subagents_dir = candidate
                            break

                    if subagents_dir:
                        for sf in glob.glob(os.path.join(subagents_dir, 'agent-*.jsonl')):
                            try:
                                full_text = sf_model = sf_session = ''
                                for raw in open(sf):
                                    raw = raw.strip()
                                    if not raw:
                                        continue
                                    try:
                                        d = json.loads(raw)
                                    except:
                                        continue
                                    if not sf_session and d.get('sessionId'):
                                        sf_session = d['sessionId']
                                    msg = d.get('message', {})
                                    if not sf_model and msg.get('model'):
                                        sf_model = msg['model']
                                    if not full_text:
                                        content = msg.get('content', '')
                                        if isinstance(content, list):
                                            for c in content:
                                                if c.get('type') == 'text':
                                                    full_text = c.get('text', '')
                                                    break
                                        elif isinstance(content, str):
                                            full_text = content
                                matched = None
                                rm = re.search(r'You are the (\w[\w\s-]*?) on team', full_text, re.I)
                                if rm:
                                    role_name = rm.group(1).strip().lower()
                                    for mname in members_cfg:
                                        if mname.lower() == role_name or role_name.startswith(mname.lower()):
                                            matched = mname
                                            break
                                if not matched:
                                    for mname in members_cfg:
                                        if mname.lower() in full_text.lower():
                                            matched = mname
                                            break
                                if matched and matched not in member_subagent:
                                    member_subagent[matched]  = sf
                                    subagent_model[matched]   = sf_model
                                    subagent_session[matched] = sf_session
                            except:
                                pass

                    inboxes_dir = os.path.join(TEAMS_DIR, tname, 'inboxes')
                    members_out = []
                    for mname, mcfg in members_cfg.items():
                        member_tasks = [t for t in tasks if t.get('owner') == mname]
                        activity = {'status': 'idle', 'activity': '', 'tool': ''}
                        sp = member_subagent.get(mname)
                        if sp:
                            activity = state_to_result(refresh_activity(sp))
                        last_msg = None
                        inbox_path = os.path.join(inboxes_dir, mname + '.json')
                        if os.path.exists(inbox_path):
                            try:
                                msgs = json.load(open(inbox_path))
                                for m in reversed(msgs):
                                    try:
                                        txt = m.get('text', '')
                                        parsed = json.loads(txt) if txt.startswith('{') else None
                                        if parsed and parsed.get('type') in ('task_assignment', 'idle_notification'):
                                            continue
                                    except:
                                        pass
                                    last_msg = {'from': m.get('from', ''), 'text': m.get('text', '')[:200],
                                                'summary': m.get('summary', ''), 'timestamp': m.get('timestamp', '')}
                                    break
                            except:
                                pass

                        is_lead = mcfg.get('agentType') == 'team-lead' or mname == 'team-lead'
                        members_out.append({
                            'name': mname,
                            'agentType': mcfg.get('agentType', 'general-purpose'),
                            'isLead': is_lead,
                            'model': subagent_model.get(mname) or mcfg.get('model', ''),
                            'color': mcfg.get('color', ''),
                            'tasks': member_tasks,
                            'activity': activity,
                            'lastMessage': last_msg,
                            'subagentFile': os.path.basename(sp) if sp else '',
                            'sessionId': subagent_session.get(mname, ''),
                        })
                    members_out.sort(key=lambda m: (0 if m['isLead'] else 1, m['name']))
                    result.append({
                        'name': cfg.get('name', tname),
                        'description': cfg.get('description', ''),
                        'leadAgentId': cfg.get('leadAgentId', ''),
                        'leadSessionId': lead_session_id,
                        'members': members_out,
                        'tasks': tasks,
                    })
            except Exception as e:
                _json_response(self, {'teams': [], 'error': str(e)})
                return
            _json_response(self, {'teams': result})
            return

        # ── /sessions ──
        if path == '/sessions':
            with _data_lock:
                agents = list(_current_data.get('agents', []))
                active_sessions = set(p['sessionId'] for p in _current_data.get('processes', []) if p.get('sessionId'))
            name_by_id = load_session_names()
            sessions = list_all_sessions(active_sessions, agents, name_by_id)
            _json_response(self, sessions)
            return

        # ── /stats ──
        if path == '/stats':
            with _data_lock:
                agents = list(_current_data.get('agents', []))
                active_sessions = set(p['sessionId'] for p in _current_data.get('processes', []) if p.get('sessionId'))
            name_by_id = load_session_names()
            sessions = list_all_sessions(active_sessions, agents, name_by_id)
            active_only = [s for s in sessions if s['is_active']]
            total_cost = sum(s['cost_usd'] for s in sessions)
            total_input = sum(s['tokens']['input'] for s in sessions)
            total_output = sum(s['tokens']['output'] for s in sessions)
            _json_response(self, {
                'active_sessions': len(active_sessions),
                'sessions': active_only,
                'total_cost_usd': round(total_cost, 4),
                'total_tokens': {'input': total_input, 'output': total_output},
            })
            return

        # ── /stream/<session_id>  (SSE tail) ──
        if path.startswith('/stream/'):
            session_id = path[len('/stream/'):]
            jsonl_path = find_jsonl(session_id)
            if not jsonl_path:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Connection', 'keep-alive')
            self.cors()
            self.end_headers()
            try:
                with open(jsonl_path, 'rb') as f:
                    f.seek(0, 2)
                    size  = f.tell()
                    start = max(0, size - 32768)
                    f.seek(start)
                    chunk  = f.read().decode('utf-8', errors='replace')
                    offset = size
                history = []
                for line in chunk.split('\n'):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        d   = json.loads(line)
                        evt = _line_to_event(d)
                        if evt:
                            history.append(evt)
                    except:
                        pass
                for evt in history[-40:]:
                    self.wfile.write(f'data: {json.dumps(evt)}\n\n'.encode())
                self.wfile.flush()
                buf = ''
                while True:
                    try:
                        new_size = os.stat(jsonl_path).st_size
                    except:
                        break
                    if new_size > offset:
                        with open(jsonl_path, 'rb') as f:
                            f.seek(offset)
                            new_bytes = f.read(new_size - offset)
                        offset = new_size
                        text   = buf + new_bytes.decode('utf-8', errors='replace')
                        lines  = text.split('\n')
                        buf    = lines.pop()
                        for line in lines:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                d   = json.loads(line)
                                evt = _line_to_event(d)
                                if evt:
                                    self.wfile.write(f'data: {json.dumps(evt)}\n\n'.encode())
                                    self.wfile.flush()
                            except:
                                pass
                    time.sleep(0.15)
            except:
                pass
            return

        self.send_response(404)
        self.end_headers()

    def do_DELETE(self):
        parsed = urllib.parse.urlparse(self.path)
        path   = parsed.path
        params = urllib.parse.parse_qs(parsed.query)

        # ── DELETE /sessions/<id> ──
        if path.startswith('/sessions/'):
            session_id = path[len('/sessions/'):]
            # Don't handle /sessions/<id>/rename here (that's POST)
            if '/' not in session_id:
                # Kill the process with this session_id
                killed = False
                with _data_lock:
                    procs = list(_current_data.get('processes', []))
                for p in procs:
                    if p.get('sessionId') == session_id:
                        try:
                            os.kill(p['pid'], signal.SIGTERM)
                            killed = True
                        except Exception:
                            pass
                # Remove from session-names.json
                raw = load_session_names_raw()
                changed = False
                for k, v in list(raw.items()):
                    if (isinstance(v, dict) and v.get('id') == session_id) or v == session_id:
                        del raw[k]
                        changed = True
                        break
                if changed:
                    save_session_names(raw)
                _json_response(self, {'success': True, 'killed': killed, 'session_id': session_id})
                return

        # ── DELETE /agent/<id> ──
        if path.startswith('/agent/'):
            agent_id = path[len('/agent/'):]
            if re.match(r'^[\w\-]+$', agent_id):
                deleted = []
                for pattern in [f'/tmp/claude-*/*/tasks/{agent_id}.output',
                                 f'/private/tmp/claude-*/*/tasks/{agent_id}.output']:
                    for f in glob.glob(pattern):
                        try:
                            os.remove(f)
                            deleted.append(f)
                        except:
                            pass
                _json_response(self, {'success': True, 'deleted': deleted})
            else:
                _json_response(self, {'error': 'Invalid agent id'}, 400)
            return

        if path == '/team':
            name_list = params.get('name', [])
            if not name_list:
                _json_response(self, {'error': 'Missing name'}, 400)
                return
            team_name = name_list[0]
            # Resolve actual directory name (may differ from config 'name' field)
            actual = None
            if os.path.isdir(os.path.join(TEAMS_DIR, team_name)):
                actual = team_name
            elif os.path.isdir(TEAMS_DIR):
                for d in os.listdir(TEAMS_DIR):
                    try:
                        cfg = json.load(open(os.path.join(TEAMS_DIR, d, 'config.json')))
                        if cfg.get('name') == team_name:
                            actual = d
                            break
                    except:
                        pass
            deleted = []
            if actual:
                for base_dir in (TEAMS_DIR, TASKS_DIR):
                    target = os.path.join(base_dir, actual)
                    if os.path.isdir(target):
                        shutil.rmtree(target, ignore_errors=True)
                        deleted.append(base_dir)
            _json_response(self, {'success': True, 'deleted': deleted, 'resolved': actual})
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path   = parsed.path

        # ── POST /sessions/<id>/rename ──
        m = re.match(r'^/sessions/([a-f0-9-]{36})/rename$', path)
        if m:
            session_id = m.group(1)
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length) if length else b'{}'
            try:
                payload = json.loads(body)
                new_name = payload.get('name', '').strip()
            except Exception:
                _json_response(self, {'error': 'Invalid JSON'}, 400)
                return
            if not new_name:
                _json_response(self, {'error': 'Missing name'}, 400)
                return
            raw = load_session_names_raw()
            # Remove any existing mapping for this session_id (old or new format)
            for k, v in list(raw.items()):
                if (isinstance(v, dict) and v.get('id') == session_id) or v == session_id:
                    del raw[k]
                    break
            # Write in new format
            raw[new_name] = {'id': session_id}
            if save_session_names(raw):
                _json_response(self, {'success': True, 'name': new_name, 'id': session_id})
            else:
                _json_response(self, {'error': 'Failed to write session-names.json'}, 500)
            return

        # Future: POST /sessions to create new sessions
        if path == '/sessions':
            _json_response(self, {'error': 'Not implemented'}, 501)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, *_):
        pass  # silence access logs


def _line_to_event(d):
    rtype = d.get('type', '')
    ts    = d.get('timestamp', '')
    if rtype == 'assistant':
        content = d.get('message', {}).get('content', [])
        if not isinstance(content, list):
            return None
        events = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get('type') == 'text':
                txt = (block.get('text') or '').strip()
                if txt:
                    events.append({'type': 'text', 'role': 'assistant', 'text': txt[:500], 'ts': ts})
            elif block.get('type') == 'tool_use':
                name   = block.get('name', '')
                inp    = block.get('input') or {}
                icon   = TOOL_ICONS.get(name, '🔧')
                detail = inp.get('command', inp.get('file_path', inp.get('pattern', inp.get('url', str(inp)[:80]))))[:120] if inp else ''
                events.append({'type': 'tool', 'tool': name, 'icon': icon, 'detail': detail, 'ts': ts})
        return events[0] if len(events) == 1 else ({'type': 'multi', 'events': events, 'ts': ts} if events else None)
    elif rtype == 'user':
        content = d.get('message', {}).get('content', [])
        if isinstance(content, str) and content.strip():
            return {'type': 'text', 'role': 'user', 'text': content.strip()[:500], 'ts': ts}
        if isinstance(content, list):
            texts = [c.get('text', '').strip() for c in content
                     if isinstance(c, dict) and c.get('type') == 'text' and c.get('text', '').strip()]
            if texts:
                return {'type': 'text', 'role': 'user', 'text': ' '.join(texts)[:500], 'ts': ts}
    elif rtype == 'system' and d.get('subtype') == 'turn_duration':
        return {'type': 'turn_end', 'duration_ms': d.get('duration_ms', 0), 'ts': ts}
    return None


# ── Main ───────────────────────────────────────────────────────────────────────

class ReuseServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


def _install_daemon():
    script_path = os.path.abspath(__file__)
    system = platform.system()
    if system == 'Darwin':
        plist_path = os.path.expanduser('~/Library/LaunchAgents/com.claudemonitor.plist')
        plist = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claudemonitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>{sys.executable}</string>
    <string>{script_path}</string>
    <string>{PORT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/claude-monitor.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/claude-monitor.log</string>
</dict>
</plist>'''
        with open(plist_path, 'w') as f:
            f.write(plist)
        subprocess.run(['launchctl', 'load', plist_path], check=False)
        print(f'Installed launchd daemon: {plist_path}')
        print('Run: launchctl unload ~/Library/LaunchAgents/com.claudemonitor.plist  to stop.')
    elif system == 'Linux':
        service_dir = os.path.expanduser('~/.config/systemd/user')
        os.makedirs(service_dir, exist_ok=True)
        service_path = os.path.join(service_dir, 'claude-monitor.service')
        unit = f'''[Unit]
Description=Claude Monitor Server
After=network.target

[Service]
ExecStart={sys.executable} {script_path} {PORT}
Restart=always
StandardOutput=append:/tmp/claude-monitor.log
StandardError=append:/tmp/claude-monitor.log

[Install]
WantedBy=default.target
'''
        with open(service_path, 'w') as f:
            f.write(unit)
        subprocess.run(['systemctl', '--user', 'daemon-reload'], check=False)
        subprocess.run(['systemctl', '--user', 'enable', '--now', 'claude-monitor'], check=False)
        print(f'Installed systemd user service: {service_path}')
        print('Run: systemctl --user stop claude-monitor  to stop.')
    else:
        print(f'Unsupported platform for --install: {system}')


if __name__ == '__main__':
    if _args.install:
        _install_daemon()
        sys.exit(0)

    # Initial collection
    print(f'Claude Monitor — http://localhost:{PORT}')
    print(f'Platform: {platform.system()}')
    print('Collecting initial data…')
    try:
        collect_once()
    except Exception as e:
        print(f'Warning: initial collect failed: {e}')

    # Start background threads
    threading.Thread(target=collector_loop, daemon=True).start()
    threading.Thread(target=watcher_loop,   daemon=True).start()

    server = ReuseServer(('0.0.0.0', PORT), MonitorHandler)
    print(f'Listening on 0.0.0.0:{PORT}  (Ctrl+C to stop)')

    if _args.open:
        def _open_browser():
            time.sleep(0.5)
            webbrowser.open(f'http://localhost:{PORT}')
        threading.Thread(target=_open_browser, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nStopped.')
