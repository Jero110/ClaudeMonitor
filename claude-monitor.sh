#!/bin/zsh
# Claude Process Monitor - Data collector + HTTP server
# Usage: ./claude-monitor.sh

OUTPUT="/tmp/claude-monitor-data.json"
PORT=7337

collect_data() {
  # Write ps data + output file list to temp files, call single python3
  local ps_tmp="/tmp/claude-monitor-ps.txt"
  local files_tmp="/tmp/claude-monitor-files.txt"

  ps aux 2>/dev/null | grep -E "(^| )claude( |$|/)" | grep -v grep | grep -v "claude-monitor" | grep -v "zsh.*claude" > "$ps_tmp" 2>/dev/null || true
  find /tmp /private/tmp -maxdepth 5 -name "*.output" -path "*/tasks/*" 2>/dev/null > "$files_tmp" || true

  python3 /tmp/claude-monitor-collect.py "$ps_tmp" "$files_tmp" "$OUTPUT" 2>/dev/null || true
}

# Write the collector script once at startup
cat > /tmp/claude-monitor-collect.py << 'COLLECTEOF'
import json, os, glob, re, time, sys, subprocess

ps_tmp, files_tmp, OUTPUT = sys.argv[1], sys.argv[2], sys.argv[3]

UUID_RE = re.compile(r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}')

# Load session-names once
name_by_id = {}
try:
    data = json.load(open(os.path.expanduser('~/.claude/session-names.json')))
    name_by_id = {v['id']: k for k, v in data.items() if isinstance(v, dict) and 'id' in v}
except:
    pass

def get_ppid(pid):
    try:
        return int(subprocess.check_output(['ps', '-o', 'ppid=', '-p', str(pid)],
                                           stderr=subprocess.DEVNULL).decode().strip())
    except:
        return 0

def model_from_jsonl(session_id):
    projects = os.path.expanduser('~/.claude/projects')
    matches = glob.glob(os.path.join(projects, '*', session_id + '.jsonl'))
    if not matches:
        return ''
    try:
        for line in open(matches[0]):
            d = json.loads(line)
            m = d.get('message', {}).get('model', '')
            if m:
                return m
    except:
        pass
    return ''

# ── Processes ────────────────────────────────────────────────────────
processes = []
active_sessions = set()
try:
    for line in open(ps_tmp):
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 10)
        if len(parts) < 11:
            continue
        try:
            pid = int(parts[1])
            cpu = float(parts[2])
            mem = float(parts[3])
            vsz = int(parts[4])
            rss = int(parts[5])
            tty = parts[6]
            stat = parts[7]
            started = parts[8]
            elapsed = parts[9]
            cmd = parts[10].strip()
        except:
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

        session_name = name_by_id.get(session_id, '')
        if model == 'unknown' and session_id:
            jm = model_from_jsonl(session_id)
            if jm:
                model = jm

        ppid = get_ppid(pid)
        if session_id:
            active_sessions.add(session_id)

        processes.append({
            'pid': pid, 'ppid': ppid, 'cpu': cpu, 'mem': mem,
            'vsz': vsz, 'rss': rss, 'tty': tty, 'stat': stat,
            'started': started, 'time': elapsed, 'model': model,
            'source': source, 'sessionId': session_id,
            'sessionName': session_name, 'cmd': cmd,
        })
except:
    pass

# ── Agents ───────────────────────────────────────────────────────────
agents = []
now = time.time()
try:
    for f in open(files_tmp).read().strip().split('\n'):
        f = f.strip()
        if not f or not os.path.isfile(f):
            continue
        agent_id = os.path.basename(f)[:-7]
        try:
            st = os.stat(f)
            file_age = int(now - st.st_mtime)
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
                        input_tok += usage.get('input_tokens', 0)
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

        status = 'running' if (file_age < 10 and session_id and session_id in active_sessions) else 'completed'
        agents.append({
            'id': agent_id, 'sessionId': session_id,
            'sessionName': name_by_id.get(session_id, ''),
            'status': status, 'lastUpdate': mtime, 'size': size,
            'lastLine': last_line, 'model': model, 'cwd': cwd,
            'tokens': {'input': input_tok, 'output': output_tok},
        })
except:
    pass

result = {
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'processes': processes,
    'agents': agents,
    'sessionNames': name_by_id,
    'system': {},
}
with open(OUTPUT, 'w') as out:
    json.dump(result, out)
COLLECTEOF

# Kill any existing process on our port before starting
lsof -ti tcp:$PORT 2>/dev/null | xargs kill -9 2>/dev/null || true

# Collect once immediately
collect_data

# Background collector loop — fast when Claude processes are running, slow when idle
(
  while true; do
    if ps aux 2>/dev/null | grep -E "(^| )claude( |$|/)" | grep -v grep | grep -v "claude-monitor" | grep -v "zsh.*claude" | grep -q .; then
      sleep 1
    else
      sleep 5
    fi
    collect_data
  done
) &
COLLECTOR_PID=$!

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  CLAUDE MONITOR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Collector PID : $COLLECTOR_PID"
echo "  API Server    : http://localhost:$PORT"
echo "  Open in browser: claude-monitor.html"
echo "  Press Ctrl+C to stop"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Python server with CORS + /data + /kill endpoints
python3 - $PORT << 'PYEOF' &
import http.server
import json
import os
import signal
import sys
import subprocess
import urllib.parse
import threading
import time
import glob as globmod
import re as remod

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7337

# ── In-memory activity state ──────────────────────────────────────────────────
# Keyed by jsonl_path. Holds offset + parsed tool state so we only read new bytes.
_activity_lock = threading.Lock()
_activity_state = {}
# { jsonl_path: { offset, line_buf, active_tools, had_turn_duration,
#                 last_record_type, status, activity, tool,
#                 dissolved, dissolve_msg, last_mtime } }

TOOL_LABELS_PY = {
    'Read':            lambda i: 'Reading '    + os.path.basename(i.get('file_path', '') or ''),
    'Edit':            lambda i: 'Editing '    + os.path.basename(i.get('file_path', '') or ''),
    'Write':           lambda i: 'Writing '    + os.path.basename(i.get('file_path', '') or ''),
    'Bash':            lambda i: 'Running: '   + (i.get('command', '') or '')[:40],
    'Glob':            lambda i: 'Searching files',
    'Grep':            lambda i: 'Searching code',
    'WebFetch':        lambda i: 'Fetching web',
    'WebSearch':       lambda i: 'Searching web',
    'Task':            lambda i: 'Subtask: '   + (i.get('description', '') or '')[:30],
    'AskUserQuestion': lambda i: 'Waiting for answer',
    'EnterPlanMode':   lambda i: 'Planning',
    'NotebookEdit':    lambda i: 'Editing notebook',
    'SendMessage':     lambda i: 'Messaging '  + (i.get('to_agent_id', '') or ''),
    'TaskUpdate':      lambda i: 'Updating task',
    'TaskCreate':      lambda i: 'Creating task',
    'TaskList':        lambda i: 'Listing tasks',
    'TaskGet':         lambda i: 'Getting task',
}
PERMISSION_EXEMPT_PY = {'Task', 'AskUserQuestion'}

# Keywords that suggest the team/session ended
_DISSOLVE_KEYWORDS = [
    'fully dissolved', 'team is dissolved', 'has been dissolved',
    'shut down cleanly', 'all agents have shut', 'team dissolved',
    'team has completed', 'mission complete', 'all tasks completed',
    'all three agents', 'team is fully',
]

def _process_line(st, line):
    """Update activity state dict `st` with one new JSONL line."""
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
                    fn    = TOOL_LABELS_PY.get(tname)
                    label = fn(inp) if fn else ('Using ' + tname)
                    st['active_tools'][tid] = {'name': tname, 'label': label}
                    st['had_turn_duration'] = False
        # Check for dissolve in assistant text
        if isinstance(content, list):
            for block in content:
                if block.get('type') == 'text':
                    txt = (block.get('text', '') or '').lower()
                    if any(k in txt for k in _DISSOLVE_KEYWORDS):
                        st['dissolved'] = True
                        st['dissolve_msg'] = block.get('text', '')[:300]

    elif rtype == 'user':
        content = d.get('message', {}).get('content', [])
        if isinstance(content, list):
            has_tr = any(b.get('type') == 'tool_result' for b in content)
            if has_tr:
                for block in content:
                    if block.get('type') == 'tool_result':
                        st['active_tools'].pop(block.get('tool_use_id', ''), None)
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


def _refresh_activity(jsonl_path):
    """Read new bytes from jsonl_path and update in-memory state. Returns state dict."""
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
            stat = os.stat(jsonl_path)
        except:
            return st

        mtime = stat.st_mtime
        size  = stat.st_size

        # File was replaced/truncated — reset
        if size < st['offset']:
            st['offset'] = 0
            st['line_buf'] = ''
            st['active_tools'].clear()
            st['had_turn_duration'] = False
            st['dissolved'] = False
            st['dissolve_msg'] = ''

        if size > st['offset']:
            try:
                with open(jsonl_path, 'rb') as f:
                    f.seek(st['offset'])
                    new_bytes = f.read(size - st['offset'])
                st['offset'] = size
                text = st['line_buf'] + new_bytes.decode('utf-8', errors='replace')
                lines = text.split('\n')
                st['line_buf'] = lines.pop()
                for line in lines:
                    _process_line(st, line)
            except:
                pass

        st['last_mtime'] = mtime
        return st


def _state_to_result(st, jsonl_path):
    """Convert in-memory state to the { status, activity, tool, dissolved, dissolve_msg } dict."""
    file_age = time.time() - st.get('last_mtime', 0)

    if st.get('dissolved'):
        return {
            'status': 'dissolved',
            'activity': 'Team dissolved',
            'tool': '',
            'dissolved': True,
            'dissolve_msg': st.get('dissolve_msg', ''),
        }

    if st['active_tools']:
        # Prefer non-exempt tool
        chosen = None
        for t in st['active_tools'].values():
            if t['name'] not in PERMISSION_EXEMPT_PY:
                chosen = t; break
        if not chosen:
            chosen = next(iter(st['active_tools'].values()))
        return {'status': 'active', 'activity': chosen['label'], 'tool': chosen['name'],
                'dissolved': False, 'dissolve_msg': ''}

    if st['had_turn_duration']:
        return {'status': 'waiting', 'activity': 'Waiting for input', 'tool': '',
                'dissolved': False, 'dissolve_msg': ''}

    # Heuristic: if file not modified in >12s and last event wasn't a new user turn → waiting
    if file_age > 12 and st['last_record_type'] == 'assistant':
        return {'status': 'waiting', 'activity': 'Waiting for input', 'tool': '',
                'dissolved': False, 'dissolve_msg': ''}

    return {'status': 'idle', 'activity': '', 'tool': '', 'dissolved': False, 'dissolve_msg': ''}


def _find_jsonl(session_id, cwd_param=''):
    """Locate the JSONL file for a session ID."""
    projects_dir = os.path.expanduser('~/.claude/projects')
    matches = globmod.glob(os.path.join(projects_dir, '*', session_id + '.jsonl'))
    if not matches and cwd_param:
        encoded = cwd_param.replace('/', '-').lstrip('-')
        proj_dir = os.path.join(projects_dir, encoded)
        candidates = globmod.glob(os.path.join(proj_dir, '*.jsonl'))
        if candidates:
            matches = [max(candidates, key=os.path.getmtime)]
    if not matches:
        all_jsonl = globmod.glob(os.path.join(projects_dir, '*', '*.jsonl'))
        if all_jsonl:
            matches = [max(all_jsonl, key=os.path.getmtime)]
    return matches[0] if matches else None


# ── Background watcher thread ─────────────────────────────────────────────────
# Reads new bytes from all known JSONL files every 300ms to keep state fresh.

def _watcher_loop():
    while True:
        with _activity_lock:
            paths = list(_activity_state.keys())
        for p in paths:
            try:
                st = _refresh_activity(p)
                if st.get('dissolved'):
                    _auto_delete_team_for_jsonl(p)
            except:
                pass
        time.sleep(0.3)

def _auto_delete_team_for_jsonl(jsonl_path):
    """If this JSONL belongs to a team lead session, delete the team directory."""
    import shutil
    teams_dir = os.path.expanduser('~/.claude/teams')
    if not os.path.isdir(teams_dir):
        return
    # Extract session ID from path (filename without .jsonl)
    session_id = os.path.splitext(os.path.basename(jsonl_path))[0]
    for team_name in os.listdir(teams_dir):
        cfg_path = os.path.join(teams_dir, team_name, 'config.json')
        try:
            cfg = json.load(open(cfg_path))
            if cfg.get('leadSessionId') == session_id:
                shutil.rmtree(os.path.join(teams_dir, team_name), ignore_errors=True)
                # Also remove from activity state so watcher stops tracking it
                with _activity_lock:
                    _activity_state.pop(jsonl_path, None)
                break
        except:
            pass

_watcher = threading.Thread(target=_watcher_loop, daemon=True)
_watcher.start()

# ─────────────────────────────────────────────────────────────────────────────

TOOL_ICONS = {
    'Read': '📄', 'Edit': '✏️', 'Write': '💾', 'Bash': '⚡',
    'Glob': '🔍', 'Grep': '🔎', 'WebFetch': '🌐', 'WebSearch': '🌐',
    'Task': '🤖', 'AskUserQuestion': '❓', 'TodoWrite': '📋',
    'NotebookEdit': '📓', 'SendMessage': '✉️',
}

def _line_to_event(d):
    """Convert a JSONL record to a simple event dict for SSE, or None to skip."""
    rtype = d.get('type', '')
    ts = d.get('timestamp', '')

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
                name = block.get('name', '')
                inp = block.get('input') or {}
                icon = TOOL_ICONS.get(name, '🔧')
                if name == 'Bash':
                    detail = (inp.get('command') or '')[:120]
                elif name in ('Read', 'Edit', 'Write'):
                    detail = inp.get('file_path', '')
                elif name == 'Glob':
                    detail = inp.get('pattern', '')
                elif name == 'Grep':
                    detail = inp.get('pattern', '') + (' in ' + inp.get('path','') if inp.get('path') else '')
                elif name == 'Task':
                    detail = inp.get('description', '')[:80]
                elif name == 'WebFetch' or name == 'WebSearch':
                    detail = inp.get('url', inp.get('query', ''))[:80]
                else:
                    detail = str(inp)[:80] if inp else ''
                events.append({'type': 'tool', 'tool': name, 'icon': icon, 'detail': detail, 'ts': ts})
        if len(events) == 1:
            return events[0]
        if events:
            return {'type': 'multi', 'events': events, 'ts': ts}
        return None

    elif rtype == 'user':
        content = d.get('message', {}).get('content', [])
        if isinstance(content, str) and content.strip():
            return {'type': 'text', 'role': 'user', 'text': content.strip()[:500], 'ts': ts}
        if isinstance(content, list):
            # Only show plain user text (not tool_result noise)
            texts = [c.get('text','').strip() for c in content if isinstance(c,dict) and c.get('type')=='text' and c.get('text','').strip()]
            if texts:
                return {'type': 'text', 'role': 'user', 'text': ' '.join(texts)[:500], 'ts': ts}
        return None

    elif rtype == 'system' and d.get('subtype') == 'turn_duration':
        ms = d.get('duration_ms', 0)
        return {'type': 'turn_end', 'duration_ms': ms, 'ts': ts}

    return None


class MonitorHandler(http.server.BaseHTTPRequestHandler):
    def send_cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache, no-store')

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors()
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        params = urllib.parse.parse_qs(parsed.query)

        if path == '/data':
            try:
                with open('/tmp/claude-monitor-data.json', 'r') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(data.encode())
            except Exception as e:
                self.send_response(500)
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'error': str(e)}).encode())

        elif path == '/kill':
            pid_list = params.get('pid', [])
            if not pid_list:
                self.send_response(400)
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'error': 'Missing pid'}).encode())
                return
            try:
                pid = int(pid_list[0])
                os.kill(pid, signal.SIGTERM)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'success': True, 'pid': pid}).encode())
            except ProcessLookupError:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'error': 'Process not found'}).encode())
            except PermissionError:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'error': 'Permission denied'}).encode())
            except Exception as e:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())
        elif path.startswith('/session/'):
            session_id = path[len('/session/'):]
            cwd_param = params.get('cwd', [''])[0]
            try:
                projects_dir = os.path.expanduser('~/.claude/projects')
                matches = globmod.glob(os.path.join(projects_dir, '*', session_id + '.jsonl'))
                if not matches:
                    # Session file not written yet — search by cwd-encoded project folder
                    if cwd_param:
                        encoded = cwd_param.replace('/', '-').lstrip('-')
                        proj_dir = os.path.join(projects_dir, encoded)
                        candidates = globmod.glob(os.path.join(proj_dir, '*.jsonl'))
                        if candidates:
                            matches = [max(candidates, key=os.path.getmtime)]
                    if not matches:
                        # Fallback: most recently modified .jsonl anywhere
                        all_jsonl = globmod.glob(os.path.join(projects_dir, '*', '*.jsonl'))
                        if not all_jsonl:
                            raise FileNotFoundError('no session files found')
                        matches = [max(all_jsonl, key=os.path.getmtime)]
                messages = []
                with open(matches[0], 'r') as f:
                    for line in f:
                        try:
                            d = json.loads(line)
                            msg = d.get('message', {})
                            role = msg.get('role', '')
                            if role not in ('user', 'assistant'):
                                continue
                            content = msg.get('content', '')
                            text = ''
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
                                        inp = c.get('input', {}) or {}
                                        name = c.get('name', '')
                                        if name == 'Bash':
                                            parts.append('[Bash] ' + (inp.get('command', '') or '')[:80])
                                        elif name in ('Read', 'Edit', 'Write'):
                                            parts.append(f'[{name}] ' + os.path.basename(inp.get('file_path', '') or ''))
                                        elif name:
                                            parts.append(f'[{name}]')
                                    elif c.get('type') == 'tool_result':
                                        # skip tool results — too noisy
                                        pass
                                text = ' '.join(parts).strip()
                            if text:
                                messages.append({'role': role, 'content': text})
                        except:
                            pass
                # Return last 10 messages
                result = messages[-10:]
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'messages': result}).encode())
            except Exception as e:
                self.send_response(404)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'error': str(e)}).encode())

        elif path.startswith('/agent/'):
            agent_id = path[len('/agent/'):]
            try:
                matches = globmod.glob(f'/private/tmp/claude-*/*/tasks/{agent_id}.output') + \
                          globmod.glob(f'/tmp/claude-*/*/tasks/{agent_id}.output')
                if not matches:
                    raise FileNotFoundError('agent output not found')
                messages = []
                with open(matches[0], 'r') as f:
                    for line in f:
                        try:
                            d = json.loads(line)
                            msg = d.get('message', {})
                            role = msg.get('role', '')
                            if role not in ('user', 'assistant'):
                                continue
                            content = msg.get('content', '')
                            text = ''
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
                                        inp = c.get('input', {}) or {}
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
                result = messages[-10:]
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'messages': result}).encode())
            except Exception as e:
                self.send_response(404)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'error': str(e)}).encode())

        elif path == '/teams':
            try:
                teams_dir = os.path.expanduser('~/.claude/teams')
                tasks_dir = os.path.expanduser('~/.claude/tasks')
                projects_dir = os.path.expanduser('~/.claude/projects')
                result = []
                if not os.path.isdir(teams_dir):
                    raise FileNotFoundError('no teams dir')

                for team_name in sorted(os.listdir(teams_dir)):
                    cfg_path = os.path.join(teams_dir, team_name, 'config.json')
                    if not os.path.exists(cfg_path):
                        continue
                    try:
                        cfg = json.load(open(cfg_path))
                    except:
                        continue

                    lead_session_id = cfg.get('leadSessionId', '')

                    # Auto-delete if lead session is already dissolved
                    lead_jsonl = _find_jsonl(lead_session_id)
                    if lead_jsonl:
                        lead_st = _refresh_activity(lead_jsonl)
                        if lead_st.get('dissolved'):
                            _auto_delete_team_for_jsonl(lead_jsonl)
                            continue

                    members_cfg = {m['name']: m for m in cfg.get('members', [])}

                    # Load tasks for this team
                    tasks_path = os.path.join(tasks_dir, team_name)
                    tasks = []
                    if os.path.isdir(tasks_path):
                        for tf in sorted(os.listdir(tasks_path)):
                            if tf.endswith('.json'):
                                try:
                                    t = json.load(open(os.path.join(tasks_path, tf)))
                                    if not t.get('metadata', {}).get('_internal'):
                                        tasks.append(t)
                                except:
                                    pass

                    # Find subagent JSONL files under the lead session
                    subagents_dir = None
                    for proj_dir in globmod.glob(os.path.join(projects_dir, '*')):
                        candidate = os.path.join(proj_dir, lead_session_id, 'subagents')
                        if os.path.isdir(candidate):
                            subagents_dir = candidate
                            break

                    # Build member -> subagent mapping by scanning all lines for member name mentions
                    member_subagent = {}   # member_name -> jsonl_path
                    subagent_model = {}    # member_name -> model string
                    subagent_session = {}  # member_name -> session_id
                    if subagents_dir:
                        for sf in globmod.glob(os.path.join(subagents_dir, 'agent-*.jsonl')):
                            try:
                                full_text = ''
                                sf_model = ''
                                sf_session = ''
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
                                # Try to match member name anywhere in the first user message
                                matched = None
                                role_match = remod.search(r'You are the (\w[\w\s-]*?) on team', full_text, remod.I)
                                if role_match:
                                    role_name = role_match.group(1).strip().lower()
                                    for mname in members_cfg:
                                        if mname.lower() == role_name or role_name.startswith(mname.lower()):
                                            matched = mname
                                            break
                                if not matched:
                                    # Fallback: find which member name appears in the prompt text
                                    for mname in members_cfg:
                                        if mname.lower() in full_text.lower():
                                            matched = mname
                                            break
                                if matched and matched not in member_subagent:
                                    member_subagent[matched] = sf
                                    if sf_model:
                                        subagent_model[matched] = sf_model
                                    if sf_session:
                                        subagent_session[matched] = sf_session
                            except:
                                pass

                    # Load last inbox message for each member
                    inboxes_dir = os.path.join(teams_dir, team_name, 'inboxes')

                    # Build members list with full info
                    members_out = []
                    for mname, mcfg in members_cfg.items():
                        # Tasks owned by this member
                        member_tasks = [t for t in tasks if t.get('owner') == mname]

                        # Activity from subagent JSONL
                        activity = {'status': 'idle', 'activity': '', 'tool': ''}
                        subagent_path = member_subagent.get(mname)
                        if subagent_path:
                            st = _refresh_activity(subagent_path)
                            activity = _state_to_result(st, subagent_path)

                        # Last inbox message (received by this member)
                        last_msg = None
                        inbox_path = os.path.join(inboxes_dir, mname + '.json')
                        if os.path.exists(inbox_path):
                            try:
                                msgs = json.load(open(inbox_path))
                                if msgs:
                                    # Find last non-internal message
                                    for m in reversed(msgs):
                                        try:
                                            txt = m.get('text', '')
                                            parsed = json.loads(txt) if txt.startswith('{') else None
                                            if parsed and parsed.get('type') in ('task_assignment', 'idle_notification'):
                                                continue
                                        except:
                                            pass
                                        last_msg = {'from': m.get('from', ''), 'text': m.get('text', '')[:200], 'summary': m.get('summary', ''), 'timestamp': m.get('timestamp', '')}
                                        break
                            except:
                                pass

                        is_lead = mcfg.get('agentType') == 'team-lead' or mname == 'team-lead'
                        real_model = subagent_model.get(mname) or mcfg.get('model', '')
                        members_out.append({
                            'name': mname,
                            'agentType': mcfg.get('agentType', 'general-purpose'),
                            'isLead': is_lead,
                            'model': real_model,
                            'color': mcfg.get('color', ''),
                            'tasks': member_tasks,
                            'activity': activity,
                            'lastMessage': last_msg,
                            'subagentFile': os.path.basename(subagent_path) if subagent_path else '',
                            'sessionId': subagent_session.get(mname, ''),
                        })

                    # Sort: lead first, then others
                    members_out.sort(key=lambda m: (0 if m['isLead'] else 1, m['name']))

                    result.append({
                        'name': cfg.get('name', team_name),
                        'description': cfg.get('description', ''),
                        'leadAgentId': cfg.get('leadAgentId', ''),
                        'leadSessionId': lead_session_id,
                        'members': members_out,
                        'tasks': tasks,
                    })

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'teams': result}).encode())
            except Exception as e:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'teams': [], 'error': str(e)}).encode())

        elif path == '/activity-bulk':
            # ?ids=sid1,sid2,... — returns all activity states in one shot
            ids_param = params.get('ids', [''])[0]
            session_ids = [s.strip() for s in ids_param.split(',') if s.strip()]
            result = {}
            for sid in session_ids:
                try:
                    jsonl_path = _find_jsonl(sid)
                    if jsonl_path:
                        st = _refresh_activity(jsonl_path)
                        result[sid] = _state_to_result(st, jsonl_path)
                    else:
                        result[sid] = {'status': 'idle', 'activity': '', 'tool': '', 'dissolved': False, 'dissolve_msg': ''}
                except:
                    result[sid] = {'status': 'idle', 'activity': '', 'tool': '', 'dissolved': False, 'dissolve_msg': ''}
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_cors()
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())

        elif path.startswith('/activity/'):
            session_id = path[len('/activity/'):]
            cwd_param = params.get('cwd', [''])[0]
            try:
                jsonl_path = _find_jsonl(session_id, cwd_param)
                if not jsonl_path:
                    result = {'status': 'idle', 'activity': '', 'tool': '', 'dissolved': False, 'dissolve_msg': ''}
                else:
                    st = _refresh_activity(jsonl_path)
                    result = _state_to_result(st, jsonl_path)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps(result).encode())
            except Exception as e:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'status': 'idle', 'activity': '', 'tool': '', 'dissolved': False, 'dissolve_msg': ''}).encode())

        elif path.startswith('/stream/'):
            session_id = path[len('/stream/'):]
            jsonl_path = _find_jsonl(session_id)
            if not jsonl_path:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Connection', 'keep-alive')
            self.send_cors()
            self.end_headers()
            try:
                offset = 0
                buf = ''
                # Send existing lines first (last 40 lines)
                with open(jsonl_path, 'rb') as f:
                    f.seek(0, 2)
                    size = f.tell()
                    # Read up to last 32KB for history
                    start = max(0, size - 32768)
                    f.seek(start)
                    chunk = f.read().decode('utf-8', errors='replace')
                    offset = size
                lines = chunk.split('\n')
                history = []
                for line in lines:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        d = json.loads(line)
                        evt = _line_to_event(d)
                        if evt:
                            history.append(evt)
                    except:
                        pass
                # Send last 40 history events
                for evt in history[-40:]:
                    msg = json.dumps(evt)
                    self.wfile.write(f'data: {msg}\n\n'.encode())
                self.wfile.flush()
                # Now tail for new lines
                while True:
                    try:
                        stat = os.stat(jsonl_path)
                        new_size = stat.st_size
                    except:
                        break
                    if new_size > offset:
                        with open(jsonl_path, 'rb') as f:
                            f.seek(offset)
                            new_bytes = f.read(new_size - offset)
                        offset = new_size
                        text = buf + new_bytes.decode('utf-8', errors='replace')
                        raw_lines = text.split('\n')
                        buf = raw_lines.pop()
                        for line in raw_lines:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                d = json.loads(line)
                                evt = _line_to_event(d)
                                if evt:
                                    msg = json.dumps(evt)
                                    self.wfile.write(f'data: {msg}\n\n'.encode())
                                    self.wfile.flush()
                            except:
                                pass
                    time.sleep(0.15)
            except:
                pass

        else:
            self.send_response(404)
            self.end_headers()

    def do_DELETE(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        params = urllib.parse.parse_qs(parsed.query)

        if path == '/team':
            import shutil
            name_list = params.get('name', [])
            if not name_list:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.send_cors()
                self.end_headers()
                self.wfile.write(json.dumps({'error': 'Missing name'}).encode())
                return
            team_name = name_list[0]
            teams_dir = os.path.expanduser('~/.claude/teams')
            tasks_dir = os.path.expanduser('~/.claude/tasks')
            # Find the actual directory: try direct match first, then scan config.json name fields
            actual_dir_name = None
            if os.path.isdir(os.path.join(teams_dir, team_name)):
                actual_dir_name = team_name
            elif os.path.isdir(teams_dir):
                for d in os.listdir(teams_dir):
                    cfg_path = os.path.join(teams_dir, d, 'config.json')
                    try:
                        cfg = json.load(open(cfg_path))
                        if cfg.get('name') == team_name:
                            actual_dir_name = d
                            break
                    except:
                        pass
            deleted = []
            if actual_dir_name:
                team_dir = os.path.join(teams_dir, actual_dir_name)
                task_dir = os.path.join(tasks_dir, actual_dir_name)
                if os.path.isdir(team_dir):
                    shutil.rmtree(team_dir, ignore_errors=True)
                    deleted.append('team config')
                if os.path.isdir(task_dir):
                    shutil.rmtree(task_dir, ignore_errors=True)
                    deleted.append('tasks')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_cors()
            self.end_headers()
            self.wfile.write(json.dumps({'success': True, 'deleted': deleted, 'resolved': actual_dir_name}).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress access logs

class ReuseServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

os.chdir(os.path.expanduser('~/Desktop/other/Vs/ClaudeMonitor'))
server = ReuseServer(('localhost', PORT), MonitorHandler)
server.serve_forever()
PYEOF

SERVER_PID=$!

trap "kill $COLLECTOR_PID $SERVER_PID 2>/dev/null; echo '\nMonitor stopped.'" EXIT INT TERM

wait
