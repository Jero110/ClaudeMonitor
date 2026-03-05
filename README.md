# Claude Monitor

A local dashboard to monitor Claude Code processes and agents running on your Mac. Real-time view of every Claude session, its sub-agents, conversation messages, tokens, and duration.

## What it shows

- Active Claude Code processes (PID, model, CPU, memory, session name)
- Sub-agents launched by each process (status: running/completed, last output, duration)
- Process → Agent tree view
- Last conversation messages per process (auto-refreshes)
- Agents tab (active) and Tasks tab (full history)
- Draggable panel resizer

## Requirements

- macOS
- Claude Code CLI installed
- Python 3 (pre-installed on macOS)
- zsh or bash

## Installation

```bash
git clone https://github.com/Jero110/ClaudeMonitor.git ~/Desktop/other/Vs/ClaudeMonitor
cd ~/Desktop/other/Vs/ClaudeMonitor
chmod +x start.sh claude-monitor.sh
```

## Start the monitor

```bash
zsh ~/Desktop/other/Vs/ClaudeMonitor/start.sh
```

That's it. No `.zshrc` changes needed. The script:
1. Kills any leftover process on port 7337
2. Starts the data collector + API server
3. Opens `claude-monitor.html` in your browser
4. Press **Ctrl+C** to stop cleanly

## Optional: add a shortcut

If you want a short command, add one line to your `~/.zshrc`:

```zsh
alias claude-monitor="zsh ~/Desktop/other/Vs/ClaudeMonitor/start.sh"
```

Then run it with:

```bash
claude-monitor
```

## Dashboard

### Process table (left panel)

| Column | Description |
|--------|-------------|
| Session | Named session or UUID prefix |
| PID | Process ID |
| Model | haiku / sonnet / opus |
| Source | How Claude was launched (terminal / vscode) |
| TTY | Terminal device |
| CPU / MEM | Resource usage |

Click any process row to expand and see:
- Last user + assistant message (auto-refreshes every 5s)
- Sub-agents launched by that session
- Full command, RSS, VSZ, stat

### Right panel

Two tabs:
- **Agents** — tasks linked to an active process. Click to expand last messages.
- **Tasks** — full history of all agent output files. Click to expand last messages.

The divider between left and right panels is draggable.

### Process tree

Shows the parent→child relationship between processes and their sub-agents.

## How it works

- Reads live process list via `ps aux`
- Reads agent output from `/tmp/claude-*/tasks/*.output`
- Detects agent status by file modification time (active if modified within last 10s and parent session is alive)
- Reads conversation history from `~/.claude/projects/<project>/<sessionId>.jsonl`
- Serves JSON at `http://localhost:7337/data`
- Auto-refreshes every 5 seconds

## Stop the monitor

Press **Ctrl+C** in the terminal running `start.sh`, or:

```bash
pkill -9 -f "claude-monitor.sh"; lsof -ti tcp:7337 | xargs kill -9 2>/dev/null
```
