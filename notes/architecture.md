# Claude Monitor — Architecture Overview

## High-Level Design

Claude Monitor is a single-shell-script tool split into two concurrent processes that together
provide a live, browser-based view of every Claude Code session running on the local machine.

```
claude-monitor.sh
  ├── Bash collector loop  (background subshell, every 2 s)
  │     └── writes  →  /tmp/claude-monitor-data.json
  └── Python HTTP server   (port 7337)
        └── reads   ←  /tmp/claude-monitor-data.json
              └── serves  →  browser (claude-monitor.html)
```

## Bash Collector Loop

`collect_data()` runs once at startup, then repeats every 2 seconds in a background subshell.

Each cycle it:
1. Runs `ps aux` and filters lines matching the `claude` binary.
2. For each process, extracts PID, CPU, memory, VSZ, RSS, TTY, stat, and the full command string.
3. Detects the active model by scanning the command for `--model <name>`.
4. Resolves a human-readable session name by matching the session UUID against
   `~/.claude/session-names.json` (via an inline `python3` call).
5. Discovers sub-agent task output files under `/tmp/claude-*/*/tasks/*.output` and parses
   each JSONL file for model name, token usage, working directory, and last assistant text.
6. Determines agent status (`running` vs `completed`) by cross-referencing each agent's
   `sessionId` against the set of currently alive Claude PIDs.
7. Writes a single JSON document to `/tmp/claude-monitor-data.json` with keys:
   `timestamp`, `processes`, `agents`, and `sessionNames`.

## Python HTTP Server

An embedded `python3` heredoc is started as a second background process on `localhost:7337`.
It uses `http.server.HTTPServer` with a custom handler that exposes four routes:

| Route | Purpose |
|---|---|
| `GET /data` | Reads and returns `/tmp/claude-monitor-data.json` verbatim. |
| `GET /kill?pid=N` | Sends `SIGTERM` to the specified PID (process management). |
| `GET /session/<id>` | Reads the session's JSONL file from `~/.claude/projects/` and returns the last 10 messages. |
| `GET /agent/<id>` | Reads the agent's `.output` file from `/tmp/` and returns the last 10 messages. |

All responses include permissive CORS headers so the HTML file can be opened as a local
`file://` URL without a same-origin policy error.

## HTML Dashboard

`claude-monitor.html` is a self-contained single-page application with no build step.
It runs entirely in the browser and:

1. Polls `http://localhost:7337/data` every 5 seconds via `fetch()`.
2. Renders two tables — active processes and sub-agents — updating in place on each tick.
3. On row click, fetches `/session/<id>` or `/agent/<id>` to show the last conversation
   messages in an inline panel.
4. Offers a Kill button per process that calls `/kill?pid=N`.

## Data Flow Summary

```
ps aux / /tmp/.output files / ~/.claude/
        |
        v
  collect_data()  [bash, every 2 s]
        |
        v
  /tmp/claude-monitor-data.json
        |
        v
  Python /data endpoint  [localhost:7337]
        |
        v
  claude-monitor.html  [browser fetch, every 5 s]
        |
        v
  Live dashboard rendered in browser
```

The temporary JSON file acts as a simple shared-memory buffer between the bash collector and
the Python server, keeping both sides stateless and easy to restart independently.
