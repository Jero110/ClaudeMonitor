# Claude Monitor

A local dashboard to monitor Claude Code processes and agents running on your Mac. It collects live process data and serves it through a single-page browser UI, giving you a real-time view of every Claude session and its sub-agents.

## What it shows

- Active Claude Code processes (PID, model, CPU, memory, session name)
- Sub-agents launched by each process (status: running/completed, last output)
- Process → Agent tree view
- Last conversation messages per process (from `~/.claude/projects/`)
- Agent conversation output

## Requirements

- macOS
- Claude Code CLI installed
- zsh

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/Jero110/claude_Monitor.git ~/Desktop/other/Vs/ClaudeMonitor
cd ~/Desktop/other/Vs/ClaudeMonitor
```

### 2. Add to ~/.zshrc

Paste this entire block into your `~/.zshrc`:

```zsh
# ─── Named Claude Sessions (cs) ───────────────────────────────────
cs() {
  local name="$1"
  shift
  if [ -z "$name" ]; then echo "Usage: cs <name> [claude args]"; return 1; fi
  local map_file="$HOME/.claude/session-names.json"
  local existing_id=""
  if [ -f "$map_file" ]; then
    existing_id=$(python3 -c "
import json, sys
try:
  data = json.load(open('$map_file'))
  v = data.get('$name', {})
  print(v.get('id',''))
except: pass
" 2>/dev/null)
  fi
  if [ -n "$existing_id" ]; then
    echo "Resuming session: $name ($existing_id)"
    claude --resume "$existing_id" "$@"
  else
    local new_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    echo "Starting new session: $name ($new_id)"
    python3 -c "
import json, os
f = os.path.expanduser('~/.claude/session-names.json')
data = {}
if os.path.exists(f): data = json.load(open(f))
data['$name'] = {'id': '$new_id', 'cwd': os.getcwd(), 'updated': __import__('datetime').datetime.now().isoformat()}
json.dump(data, open(f,'w'), indent=2)
" 2>/dev/null
    claude --session-id "$new_id" "$@"
  fi
}

cs-list() {
  python3 -c "
import json, os
f = os.path.expanduser('~/.claude/session-names.json')
try:
  data = json.load(open(f))
  for name, v in data.items():
    cwd = v.get('cwd','').replace(os.path.expanduser('~'), '~')
    print(f'{name:<20} {v[\"id\"]:<38} {cwd}')
except:
  print('No sessions saved yet.')
" 2>/dev/null
}

# ─── Claude Monitor ───────────────────────────────────────────────
claude_monitor() {
  local monitor_dir="$HOME/Desktop/other/Vs/ClaudeMonitor"

  pkill -9 -f "claude-monitor.sh" 2>/dev/null
  pkill -9 -f "python3.*7337" 2>/dev/null
  sleep 0.3

  trap 'echo "\nStopping monitor…"; pkill -9 -f "claude-monitor.sh" 2>/dev/null; pkill -9 -f "python3.*7337" 2>/dev/null; trap - INT QUIT; return 0' INT QUIT

  echo "Starting claude monitor… (Ctrl+C to stop)"

  zsh "$monitor_dir/claude-monitor.sh" &
  local server_pid=$!

  local tries=0
  while ! curl -s http://localhost:7337/data > /dev/null 2>&1; do
    sleep 0.5
    tries=$((tries+1))
    [ $tries -gt 20 ] && echo "Failed to start. Check /tmp/claude-monitor.log" && pkill -9 -f "claude-monitor.sh" 2>/dev/null && trap - INT QUIT && return 1
  done
  echo "Ready → http://localhost:7337"
  open "$monitor_dir/claude-monitor.html"

  wait $server_pid
  trap - INT QUIT
}
# ──────────────────────────────────────────────────────────────────
```

### 3. Reload shell

```bash
source ~/.zshrc
```

### 4. Start the monitor

```bash
claude_monitor
```

This starts the server and opens the dashboard in your browser. Press **Ctrl+C** to stop.

## Usage

### Named sessions

```bash
cs myproject          # start or resume a named Claude session
cs-list               # list all saved sessions
```

### Monitor commands

```bash
claude_monitor        # start monitor + open browser (Ctrl+C to stop)
```

## Dashboard

| Column | Description |
|--------|-------------|
| PID | Process ID |
| Model | haiku / sonnet / opus |
| Source | How Claude was launched |
| Session | Named session or UUID prefix |
| CPU / MEM | Resource usage |

Click any process row to expand and see:

- Last conversation messages
- Sub-agents launched by that session
- Full command

## How it works

- Reads live process list via `ps aux`
- Reads agent output from `/tmp/claude-*/tasks/*.output`
- Reads conversation history from `~/.claude/projects/<project>/<sessionId>.jsonl`
- Serves JSON at `http://localhost:7337/data`
- Auto-refreshes every 5 seconds

## Stop the monitor

Press **Ctrl+C** in the terminal running `claude_monitor`, or run:

```bash
pkill -9 -f "claude-monitor.sh"; pkill -9 -f "python3.*7337"
```
