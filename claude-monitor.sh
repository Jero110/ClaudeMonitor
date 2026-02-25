#!/bin/zsh
# Claude Process Monitor - Data collector + HTTP server
# Usage: ./claude-monitor.sh

OUTPUT="/tmp/claude-monitor-data.json"
PORT=7337

collect_data() {
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local procs_json="["
  local first=1

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local pid=$(echo "$line" | awk '{print $2}')
    local cpu=$(echo "$line" | awk '{print $3}')
    local mem=$(echo "$line" | awk '{print $4}')
    local vsz=$(echo "$line" | awk '{print $5}')
    local rss=$(echo "$line" | awk '{print $6}')
    local tty=$(echo "$line" | awk '{print $7}')
    local stat=$(echo "$line" | awk '{print $8}')
    local started=$(echo "$line" | awk '{print $9}')
    local time=$(echo "$line" | awk '{print $10}')
    local cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf $i" "; print ""}')

    local model="unknown"
    if echo "$cmd" | grep -q "\-\-model"; then
      model=$(echo "$cmd" | grep -oE '\-\-model [a-z0-9\.\-]+' | head -1 | awk '{print $2}')
    fi

    local ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')

    local source="terminal"
    if echo "$cmd" | grep -q "vscode"; then
      source="vscode"
    fi

    # Extract session-id from cmd (--session-id, --resume, or positional UUID)
    local proc_session_id=""
    if echo "$cmd" | grep -qE '\-\-(session-id|resume) [a-f0-9\-]{36}'; then
      proc_session_id=$(echo "$cmd" | grep -oE '\-\-(session-id|resume) [a-f0-9\-]{36}' | head -1 | awk '{print $2}')
    elif echo "$cmd" | grep -qE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}'; then
      proc_session_id=$(echo "$cmd" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)
    fi

    # Lookup session name
    local proc_session_name=""
    if [ -n "$proc_session_id" ]; then
      proc_session_name=$(python3 -c "
import json, os
f = os.path.expanduser('~/.claude/session-names.json')
try:
  data = json.load(open(f))
  for name, v in data.items():
    if v.get('id') == '$proc_session_id':
      print(name); exit()
except: pass
print('')
" 2>/dev/null)
    fi

    local cmd_json=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null <<< "$cmd")
    [ -z "$cmd_json" ] && cmd_json='""'
    local proc_session_id_json=$(python3 -c "import sys,json; print(json.dumps('$proc_session_id'))" 2>/dev/null)
    [ -z "$proc_session_id_json" ] && proc_session_id_json='""'
    local proc_session_name_json=$(python3 -c "import sys,json; print(json.dumps('$proc_session_name'))" 2>/dev/null)
    [ -z "$proc_session_name_json" ] && proc_session_name_json='""'

    [ $first -eq 0 ] && procs_json+=","
    first=0
    procs_json+="{\"pid\":${pid:-0},\"ppid\":${ppid:-0},\"cpu\":${cpu:-0},\"mem\":${mem:-0},\"vsz\":${vsz:-0},\"rss\":${rss:-0},\"tty\":\"${tty}\",\"stat\":\"${stat}\",\"started\":\"${started}\",\"time\":\"${time}\",\"model\":\"${model}\",\"source\":\"${source}\",\"sessionId\":${proc_session_id_json},\"sessionName\":${proc_session_name_json},\"cmd\":${cmd_json}}"
  done < <(ps aux 2>/dev/null | grep -E "(^| )claude( |$|/)" | grep -v grep | grep -v "claude-monitor" | grep -v "zsh.*claude")

  procs_json+="]"

  # Build set of sessionIds that have an active (running) process
  local active_sessions=""
  while IFS= read -r line; do
    local sid=$(echo "$line" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)
    [ -n "$sid" ] && active_sessions="$active_sessions $sid "
  done < <(ps aux 2>/dev/null | grep -E "(^| )claude( |$|/)" | grep -v grep | grep -v "claude-monitor" | grep -v "zsh.*claude")

  # Check task output files — discover dynamically under /tmp/claude-*/*/tasks/
  local agents_json="["
  local afirst=1

  # Find all .output files across any claude task directory
  local all_outputs=()
  while IFS= read -r f; do
    all_outputs+=("$f")
  done < <(find /tmp /private/tmp -maxdepth 5 -name "*.output" -path "*/tasks/*" 2>/dev/null)

  for f in "${all_outputs[@]}"; do
      [ -f "$f" ] || continue
      local agent_id=$(basename "$f" .output)
      local mtime=$(stat -f "%Sm" -t "%H:%M:%S" "$f" 2>/dev/null || echo "unknown")
      local size=$(stat -f "%z" "$f" 2>/dev/null || echo 0)
      # Extract last human-readable text from Claude JSON output (scan all lines, take last text)
      local last_line=$(python3 -c "
import json
last = ''
try:
  for line in open('$f'):
    try:
      d = json.loads(line)
      msg = d.get('message', {})
      content = msg.get('content', [])
      for c in content:
        if isinstance(c, dict) and c.get('type') == 'text' and c.get('text','').strip():
          last = c['text'].strip()[:120]
      if d.get('type') == 'result' and d.get('result','').strip():
        last = d['result'].strip()[:120]
    except: pass
except: pass
print(last)
" 2>/dev/null)
      local agent_status="completed"
      # Check if file was modified in the last 10 seconds (agent actively writing)
      local file_age=$(python3 -c "import os,time; print(int(time.time()-os.path.getmtime('$f')))" 2>/dev/null || echo 9999)
      local last_json=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null <<< "$last_line")
      [ -z "$last_json" ] && last_json='""'

      # Extract session/parent info from output file
      local session_id=""
      local agent_model=""
      local input_tokens=0
      local output_tokens=0
      local agent_cwd=""
      local conv_data=$(python3 -c "
import sys, json
lines = open('$f').readlines()
session_id = ''
model = ''
input_tok = 0
output_tok = 0
cwd = ''
for line in lines:
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
  except: pass
print(json.dumps({'session': session_id, 'model': model, 'input': input_tok, 'output': output_tok, 'cwd': cwd}))
" 2>/dev/null || echo '{}')
      session_id=$(echo "$conv_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session',''))" 2>/dev/null)
      # Running only if parent session is active AND file modified within last 10 seconds
      if [ "$file_age" -lt 10 ] && [ -n "$session_id" ] && echo "$active_sessions" | grep -q " $session_id "; then
        agent_status="running"
      fi
      agent_model=$(echo "$conv_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model',''))" 2>/dev/null)
      input_tokens=$(echo "$conv_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('input',0))" 2>/dev/null)
      output_tokens=$(echo "$conv_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('output',0))" 2>/dev/null)
      agent_cwd=$(echo "$conv_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null)

      local session_json=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null <<< "$session_id")
      [ -z "$session_json" ] && session_json='""'
      local model_json=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null <<< "$agent_model")
      [ -z "$model_json" ] && model_json='""'
      local cwd_json=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null <<< "$agent_cwd")
      [ -z "$cwd_json" ] && cwd_json='""'

      # Lookup session name from ~/.claude/session-names.json
      local session_name=$(python3 -c "
import json, os
f = os.path.expanduser('~/.claude/session-names.json')
try:
  data = json.load(open(f))
  for name, v in data.items():
    if v.get('id') == '$session_id':
      print(name)
      exit()
except: pass
print('')
" 2>/dev/null)
      local session_name_json=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null <<< "$session_name")
      [ -z "$session_name_json" ] && session_name_json='""'

      [ $afirst -eq 0 ] && agents_json+=","
      afirst=0
      agents_json+="{\"id\":\"${agent_id}\",\"sessionId\":${session_json},\"sessionName\":${session_name_json},\"status\":\"${agent_status}\",\"lastUpdate\":\"${mtime}\",\"size\":${size},\"lastLine\":${last_json},\"model\":${model_json},\"cwd\":${cwd_json},\"tokens\":{\"input\":${input_tokens:-0},\"output\":${output_tokens:-0}}}"
  done
  agents_json+="]"

  # Build session-names lookup for processes
  local session_names_json=$(python3 -c "
import json, os
f = os.path.expanduser('~/.claude/session-names.json')
try:
  data = json.load(open(f))
  # id -> name mapping
  result = {v['id']: k for k, v in data.items()}
  print(json.dumps(result))
except:
  print('{}')
" 2>/dev/null)

  cat > "$OUTPUT" << JSONEOF
{
  "timestamp": "$timestamp",
  "processes": $procs_json,
  "agents": $agents_json,
  "sessionNames": $session_names_json,
  "system": {}
}
JSONEOF
}

# Kill any existing process on our port before starting
lsof -ti tcp:$PORT 2>/dev/null | xargs kill -9 2>/dev/null || true

# Collect once immediately
collect_data

# Background collector loop
(
  while true; do
    sleep 2
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
