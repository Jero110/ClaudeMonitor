#!/usr/bin/env python3
"""
Claude Monitor — standalone server
Works on macOS and Linux (any Python 3.8+, zero dependencies).

Usage:
    python3 claude-monitor-server.py          # port 7337
    python3 claude-monitor-server.py 8080     # custom port

Open http://localhost:<port> in your browser.
For remote VMs: ssh -L 7337:localhost:7337 user@host  then open localhost:7337
"""

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

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7337
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

# ── Shared data (collector → server) ──────────────────────────────────────────
_data_lock = threading.Lock()
_current_data = {'timestamp': '', 'processes': [], 'agents': [], 'sessionNames': {}, 'system': {}}

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
    try:
        data = json.load(open(SESSION_NAMES))
        return {v['id']: k for k, v in data.items() if isinstance(v, dict) and 'id' in v}
    except:
        return {}


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
    if st['had_turn_duration']:
        return {'status': 'waiting', 'activity': 'Waiting for input', 'tool': '',
                'dissolved': False, 'dissolve_msg': ''}
    if age > 12 and st['last_record_type'] == 'assistant':
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

    def log_message(self, format, *args):  # noqa: A002
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


if __name__ == '__main__':
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
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nStopped.')
