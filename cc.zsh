# ─── cc — Claude Code wrapper ──────────────────────────────────────────────────
# Source this file from ~/.zshrc:  source ~/Desktop/other/Vs/ClaudeMonitor/cc.zsh
#
# COMMANDS
#   cc [name] [args...]   → new/resume named session (like cs)
#   cc ls                 → list sessions (name, id, cwd, active)
#   cc rm <name>          → delete session from session-names.json + .claude/projects
#   cc rm --all           → delete all sessions
#   cc kill <name|pid>    → kill running claude process by session name or PID
#   cc ps                 → show running claude processes
#   cc monitor            → open monitor dashboard
#
# EXAMPLES
#   cc myproject
#   cc myproject --model opus
#   cc ls
#   cc rm myproject
#   cc kill myproject
#   cc ps

_CC_MAP="$HOME/.claude/session-names.json"
_CC_PROJECTS="$HOME/.claude/projects"

# Fast JSON helpers — pure shell to avoid python3 startup cost on tab-complete
_cc_get_id() {
  python3 -c "
import json,sys
try:
  d=json.load(open('$_CC_MAP'))
  v=d.get('$1',{})
  print(v.get('id','') if isinstance(v,dict) else v)
except: pass
" 2>/dev/null
}

_cc_save() {
  # _cc_save <name> <id> <cwd>
  python3 -c "
import json,os
f='$_CC_MAP'; d={}
try: d=json.load(open(f))
except: pass
d['$1']={'id':'$2','cwd':'$3','updated':'$(date -u +%Y-%m-%dT%H:%M:%SZ)'}
json.dump(d,open(f,'w'),indent=2)
" 2>/dev/null
}

# ── main command ────────────────────────────────────────────────────────────────
cc() {
  local cmd="${1:-}"

  case "$cmd" in
    ls|list) _cc_list; return ;;
    rm|delete) shift; _cc_rm "$@"; return ;;
    clean) _cc_clean; return ;;
    kill)   shift; _cc_kill "$@"; return ;;
    ps)     _cc_ps; return ;;
    monitor) claude_monitor; return ;;
    -h|--help|help)
      echo "cc [name] [args]   — start/resume named claude session"
      echo "cc ls              — list sessions"
      echo "cc rm <name|--all> — delete session"
      echo "cc clean           — delete empty/zero-token sessions"
      echo "cc kill <name|pid> — kill running process"
      echo "cc ps              — show running claude processes"
      echo "cc monitor         — open monitor dashboard"
      return ;;
  esac

  # No subcommand → treat $1 as session name
  if [ -z "$cmd" ]; then
    echo "Usage: cc <name> [claude-args...]  or  cc <subcommand>"
    echo "       cc help for full usage"
    return 1
  fi

  local name="$1"; shift
  local cwd="$(pwd)"
  local existing_id="$(_cc_get_id "$name")"

  if [ -n "$existing_id" ]; then
    echo "▶ Resuming: $name  ($existing_id)"
    _cc_save "$name" "$existing_id" "$cwd"
    command claude --resume "$existing_id" "$@"
  else
    echo "▶ New session: $name"
    command claude "$@"
  fi

  # After Claude exits, detect the real session UUID from the newest .jsonl
  # (Claude may create its own UUID, ignoring --session-id)
  _cc_sync_real_id "$name" "$cwd"
}

# ── sync real session id after claude exits ─────────────────────────────────────
_cc_sync_real_id() {
  # Finds the most recently modified .jsonl in ~/.claude/projects that matches
  # the current session name, and updates session-names.json with the real UUID.
  python3 -c "
import json, os, glob, time, datetime

name = '$1'
cwd  = '$2'
proj = os.path.expanduser('~/.claude/projects')
f    = os.path.expanduser('~/.claude/session-names.json')

# Load existing map
try:
  data = json.load(open(f))
except:
  data = {}

existing = data.get(name, {})
existing_id = existing.get('id', existing) if isinstance(existing, dict) else existing

# Find all jsonl files modified in the last 30 minutes
now = time.time()
candidates = []
for jf in glob.glob(os.path.join(proj, '*', '*.jsonl')):
  try:
    age = now - os.path.getmtime(jf)
    if age < 1800:
      candidates.append((os.path.getmtime(jf), jf))
  except:
    pass

if not candidates:
  exit()

candidates.sort(reverse=True)

# Pick the newest one whose UUID differs from what we have stored
import re
UUID_RE = re.compile(r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}')
for mtime, jf in candidates:
  sid = os.path.splitext(os.path.basename(jf))[0]
  if not UUID_RE.match(sid):
    continue
  # If we already have this id stored under this name, nothing to do
  if sid == existing_id:
    exit()
  # Skip if this UUID is already registered under a different name
  already_used = any(
    (v.get('id', v) if isinstance(v, dict) else v) == sid
    for k, v in data.items() if k != name
  )
  if already_used:
    continue
  # Check this jsonl actually belongs to cwd by reading first line
  try:
    first = open(jf).readline()
    d = json.loads(first)
    jcwd = d.get('cwd', '')
    if jcwd and cwd and not jcwd.startswith(cwd) and not cwd.startswith(jcwd):
      continue
  except:
    pass
  # Update with real id
  data[name] = {'id': sid, 'cwd': cwd, 'updated': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}
  json.dump(data, open(f, 'w'), indent=2)
  print(f'↳ Saved real session id: {sid}')
  exit()
" 2>/dev/null
}

# ── list ────────────────────────────────────────────────────────────────────────
_cc_list() {
  python3 -c "
import json, os, glob, subprocess

f = os.path.expanduser('~/.claude/session-names.json')
proj = os.path.expanduser('~/.claude/projects')

try:
  data = json.load(open(f))
except:
  print('No sessions saved.')
  exit()

# Active PIDs from ps
try:
  ps = subprocess.check_output(['ps','aux'], stderr=subprocess.DEVNULL).decode()
except:
  ps = ''

active_ids = set()
for line in ps.splitlines():
  if 'claude' in line and '--session-id' in line:
    parts = line.split('--session-id')
    if len(parts) > 1:
      active_ids.add(parts[1].split()[0].strip())
  if 'claude' in line and '--resume' in line:
    parts = line.split('--resume')
    if len(parts) > 1:
      active_ids.add(parts[1].split()[0].strip())

home = os.path.expanduser('~')
print(f\"{'ST':<3} {'NAME':<20} {'SESSION ID':<38} CWD\")
print('─'*85)
for name, v in data.items():
  sid = v.get('id','') if isinstance(v,dict) else v
  cwd = (v.get('cwd','') if isinstance(v,dict) else '').replace(home,'~')
  # check if jsonl exists
  files = glob.glob(os.path.join(proj,'*', sid+'.jsonl'))
  exists = '✓' if files else '✗'
  active = '▶' if sid in active_ids else ' '
  print(f'{active:<3} {name:<20} {sid:<38} {cwd}')
" 2>/dev/null
}

# ── rm ──────────────────────────────────────────────────────────────────────────
_cc_rm() {
  if [ -z "$1" ]; then
    echo "Usage: cc rm <name|--all>"
    return 1
  fi

  if [ "$1" = "--all" ]; then
    echo -n "Delete ALL sessions from session-names.json? [y/N] "
    read confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { echo "Cancelled."; return 0; }
    echo '{}' > "$_CC_MAP"
    echo "Cleared session-names.json (project files untouched)."
    return 0
  fi

  local name="$1"
  python3 -c "
import json, os, glob, shutil, sys

f = os.path.expanduser('~/.claude/session-names.json')
proj = os.path.expanduser('~/.claude/projects')
name = '$name'

try:
  data = json.load(open(f))
except:
  print('No sessions file found.'); sys.exit(1)

if name not in data:
  print(f'Session not found: {name}')
  print('Available: ' + ', '.join(data.keys()))
  sys.exit(1)

v = data[name]
sid = v.get('id','') if isinstance(v,dict) else v

# Remove from map
del data[name]
json.dump(data, open(f,'w'), indent=2)
print(f'Removed from session-names: {name}')

# Remove jsonl from .claude/projects
removed = []
for jf in glob.glob(os.path.join(proj, '*', sid + '.jsonl')):
  os.remove(jf)
  removed.append(jf)
  # remove parent project dir if empty
  parent = os.path.dirname(jf)
  if not os.listdir(parent):
    shutil.rmtree(parent, ignore_errors=True)

if removed:
  for r in removed:
    print(f'Deleted: {r}')
else:
  print('No .jsonl found (already gone or never created).')
" 2>/dev/null
}

# ── kill ────────────────────────────────────────────────────────────────────────
_cc_kill() {
  if [ -z "$1" ]; then
    echo "Usage: cc kill <session-name|pid>"
    return 1
  fi

  local target="$1"

  # If numeric, treat as PID directly
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    kill -TERM "$target" 2>/dev/null && echo "Sent SIGTERM to PID $target" || echo "PID $target not found"
    return
  fi

  # Resolve session name → id → find PID
  local sid="$(_cc_get_id "$target")"
  if [ -z "$sid" ]; then
    echo "Session not found: $target"
    return 1
  fi

  local pid
  pid=$(ps aux | grep -E -- "(--session-id|--resume)\s+$sid" | grep -v grep | awk '{print $2}' | head -1)
  if [ -z "$pid" ]; then
    echo "No running process found for session: $target ($sid)"
    return 1
  fi
  kill -TERM "$pid" 2>/dev/null && echo "Sent SIGTERM to PID $pid (session: $target)" || echo "Failed to kill PID $pid"
}

# ── clean ───────────────────────────────────────────────────────────────────────
_cc_clean() {
  python3 -c "
import json, os, glob

proj = os.path.expanduser('~/.claude/projects')
removed = []

for jf in glob.glob(os.path.join(proj, '*', '*.jsonl')):
  try:
    lines = open(jf).readlines()
    tokens = 0
    for line in lines:
      try:
        d = json.loads(line)
        u = d.get('message', {}).get('usage', {})
        tokens += u.get('input_tokens', 0) + u.get('output_tokens', 0)
      except: pass
    if tokens == 0:
      os.remove(jf)
      removed.append(os.path.basename(jf))
  except: pass

if removed:
  print(f'Deleted {len(removed)} empty sessions:')
  for r in removed: print(f'  {r}')
else:
  print('No empty sessions found.')
" 2>/dev/null
}

# ── ps ──────────────────────────────────────────────────────────────────────────
_cc_ps() {
  python3 -c "
import subprocess, re, json, os

try:
  out = subprocess.check_output(['ps','aux'], stderr=subprocess.DEVNULL).decode()
except:
  print('ps failed'); exit()

f = os.path.expanduser('~/.claude/session-names.json')
try:
  raw = json.load(open(f))
  id_to_name = {}
  for k,v in raw.items():
    sid = v.get('id','') if isinstance(v,dict) else v
    id_to_name[sid] = k
except:
  id_to_name = {}

print(f\"{'PID':<8} {'SESSION':<22} {'MODEL':<28} CMD\")
print('─'*80)
for line in out.splitlines():
  if not re.search(r'(^|\s)claude(\s|\$|/)', line): continue
  if any(x in line for x in ['grep','claude-monitor','claude-monitor-server']): continue
  parts = line.split(None, 10)
  if len(parts) < 11: continue
  pid = parts[1]
  cmd = parts[10]
  # find session id
  sid = ''
  for flag in ['--session-id','--resume']:
    if flag in cmd:
      after = cmd.split(flag)[1].strip().split()[0] if cmd.split(flag)[1].strip() else ''
      if after: sid = after; break
  name = id_to_name.get(sid, sid[:8]+'...' if sid else '')
  model = ''
  m = re.search(r'--model\s+(\S+)', cmd)
  if m: model = m.group(1)
  print(f'{pid:<8} {name:<22} {model:<28} claude')
" 2>/dev/null
}
# ──────────────────────────────────────────────────────────────────────────────
