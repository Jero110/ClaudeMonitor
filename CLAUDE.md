# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the Monitor

The monitor requires a one-time setup: add the `claude_monitor` and `cs` functions from the README to `~/.zshrc`, then `source ~/.zshrc`.

```bash
claude_monitor        # start server + open browser dashboard (Ctrl+C to stop)
```

Manual stop (if needed):
```bash
pkill -9 -f "claude-monitor.sh"; pkill -9 -f "python3.*7337"
```

Logs: `/tmp/claude-monitor.log`

## Architecture

Two files make up the entire project:

**`claude-monitor.sh`** — runs two concurrent processes:
1. A bash `collect_data()` loop (every 2s) that reads `ps aux`, scans `/tmp/claude-*/*/tasks/*.output` for agent output files, and resolves session names from `~/.claude/session-names.json`. Writes everything to `/tmp/claude-monitor-data.json`.
2. An embedded Python HTTP server on port `7337` with four routes: `GET /data` (serves the JSON file), `GET /kill?pid=N` (sends SIGTERM), `GET /session/<id>` (reads `~/.claude/projects/<project>/<id>.jsonl`, returns last 10 messages), `GET /agent/<id>` (reads the agent's `.output` file, returns last 10 messages).

**`claude-monitor.html`** — self-contained SPA, no build step. Polls `/data` every 5s, renders process table (left panel) and agents/tasks tabs (right panel), draggable divider between panels.

## Key Data Paths

| Path | Purpose |
|------|---------|
| `/tmp/claude-monitor-data.json` | Shared buffer between bash collector and Python server |
| `/tmp/claude-*/*/tasks/*.output` | Agent task JSONL output files |
| `~/.claude/projects/<project>/<sessionId>.jsonl` | Session conversation history |
| `~/.claude/session-names.json` | Maps human names → session UUIDs (maintained by `cs` shell function) |

## Agent Status Detection

An agent is marked `running` only if **both** conditions are true:
- Its `.output` file was modified within the last 10 seconds
- Its `sessionId` matches an active Claude process in `ps aux`

Otherwise it shows as `completed`.
