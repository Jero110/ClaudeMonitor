#!/bin/zsh
# Claude Process Monitor - Data collector + HTTP server
# Usage: ./claude-monitor.sh

OUTPUT="/tmp/claude-monitor-data.json"
PORT=7337

collect_data() {
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Collect all process lines once
  local ps_lines
  ps_lines=$(ps aux 2>/dev/null | grep -E "(^| )claude( |$|/)" | grep -v grep | grep -v "claude-monitor" | grep -v "zsh.*claude")

  # Collect all output files once
  local output_files
  output_files=$(find /tmp /private/tmp -maxdepth 5 -name "*.output" -path "*/tasks/*" 2>/dev/null)

  # Single python3 call to build entire JSON
  local result
  result=$(python3 - "$timestamp" <<PYEOF2
import json, os, sys, re, time

timestamp = sys.argv[1]
session_names_file = os.path.expanduser('~/.claude/session-names.json')

# Load session names once
try:
  session_data = json.load(open(session_names_file))
  id_to_name = {v['id']: k for k, v in session_data.items() if 'id' in v}
except:
  session_data = {}
  id_to_name = {}

# Parse processes
ps_lines = """$ps_lines"""
procs = []
active_sessions = set()
uuid_re = re.compile(r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}')

for line in ps_lines.strip().splitlines():
  if not line.strip():
    continue
  parts = line.split()
  if len(parts) < 11:
    continue
  pid = parts[1]
  cpu = parts[2]
  mem = parts[3]
  vsz = parts[4]
  rss = parts[5]
  tty = parts[6]
  stat = parts[7]
  started = parts[8]
  ptime = parts[9]
  cmd = ' '.join(parts[10:])

  model = 'unknown'
  m = re.search(r'--model ([a-z0-9.\-]+)', cmd)
  if m:
    model = m.group(1)

  try:
    ppid_out = __import__('subprocess').check_output(['ps', '-o', 'ppid=', '-p', pid], stderr=__import__('subprocess').DEVNULL).decode().strip()
    ppid = ppid_out
  except:
    ppid = '0'

  source = 'vscode' if 'vscode' in cmd else 'terminal'

  proc_session_id = ''
  m = re.search(r'--(session-id|resume) ([a-f0-9-]{36})', cmd)
  if m:
    proc_session_id = m.group(2)
  else:
    m = uuid_re.search(cmd)
    if m:
      proc_session_id = m.group(0)

  if proc_session_id:
    active_sessions.add(proc_session_id)

  proc_session_name = id_to_name.get(proc_session_id, '')

  procs.append({
    'pid': int(pid) if pid.isdigit() else 0,
    'ppid': int(ppid) if ppid.isdigit() else 0,
    'cpu': float(cpu) if cpu else 0,
    'mem': float(mem) if mem else 0,
    'vsz': int(vsz) if vsz.isdigit() else 0,
    'rss': int(rss) if rss.isdigit() else 0,
    'tty': tty, 'stat': stat, 'started': started, 'time': ptime,
    'model': model, 'source': source,
    'sessionId': proc_session_id,
    'sessionName': proc_session_name,
    'cmd': cmd
  })

# Parse agents
output_files = """$output_files"""
agents = []

for f in output_files.strip().splitlines():
  f = f.strip()
  if not f or not os.path.isfile(f):
    continue
  agent_id = os.path.basename(f)[:-7]  # remove .output
  try:
    mtime_ts = os.path.getmtime(f)
    ctime_ts = os.path.getctime(f)
    mtime = __import__('datetime').datetime.fromtimestamp(mtime_ts).strftime('%H:%M:%S')
    createdAt = __import__('datetime').datetime.fromtimestamp(ctime_ts).strftime('%H:%M:%S')
    createdAtTs = int(ctime_ts)
    mtime_ts_int = int(mtime_ts)
    size = os.path.getsize(f)
    file_age = int(time.time() - mtime_ts)
  except:
    mtime = 'unknown'; createdAt = 'unknown'; createdAtTs = 0; mtime_ts_int = 0; size = 0; file_age = 9999

  last_line = ''
  session_id = ''
  model = ''
  input_tok = 0
  output_tok = 0
  cwd = ''

  try:
    for line in open(f):
      try:
        d = json.loads(line)
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
        content = msg.get('content', [])
        for c in content:
          if isinstance(c, dict) and c.get('type') == 'text' and c.get('text','').strip():
            last_line = c['text'].strip()[:120]
        if d.get('type') == 'result' and d.get('result','').strip():
          last_line = d['result'].strip()[:120]
      except:
        pass
  except:
    pass

  agent_status = 'running' if (file_age < 10 and session_id and session_id in active_sessions) else 'completed'
  session_name = id_to_name.get(session_id, '')

  agents.append({
    'id': agent_id,
    'sessionId': session_id,
    'sessionName': session_name,
    'status': agent_status,
    'lastUpdate': mtime,
    'lastUpdateTs': mtime_ts_int,
    'createdAt': createdAt,
    'createdAtTs': createdAtTs,
    'size': size,
    'lastLine': last_line,
    'model': model,
    'cwd': cwd,
    'tokens': {'input': input_tok, 'output': output_tok}
  })

print(json.dumps({
  'timestamp': timestamp,
  'processes': procs,
  'agents': agents,
  'sessionNames': id_to_name,
  'system': {}
}))
PYEOF2
)

  echo "$result" > "$OUTPUT"
}

# Kill any existing process on our port before starting
lsof -ti tcp:$PORT 2>/dev/null | xargs kill -9 2>/dev/null || true

# Background collector loop (collect immediately then every 1s)
(
  collect_data
  while true; do
    sleep 1
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

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7337

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
                import glob as globmod
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
                            # Extract text content
                            content = msg.get('content', '')
                            text = ''
                            if isinstance(content, str):
                                text = content.strip()
                            elif isinstance(content, list):
                                parts = []
                                for c in content:
                                    if isinstance(c, dict) and c.get('type') == 'text':
                                        parts.append(c.get('text', '').strip())
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
                import glob as globmod
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
                                    if isinstance(c, dict) and c.get('type') == 'text':
                                        parts.append(c.get('text', '').strip())
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

        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress access logs

class ReuseServer(http.server.HTTPServer):
    allow_reuse_address = True

os.chdir(os.path.expanduser('~/Desktop/other/Vs/ClaudeMonitor'))
server = ReuseServer(('localhost', PORT), MonitorHandler)
server.serve_forever()
PYEOF

SERVER_PID=$!

trap "kill $COLLECTOR_PID $SERVER_PID 2>/dev/null; echo '\nMonitor stopped.'" EXIT INT TERM

wait
