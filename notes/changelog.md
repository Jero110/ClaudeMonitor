# Changelog

## v1.0.0 - 2026-02-24

Initial release of claude-monitor.

### Features

- **Process monitoring via ps aux**: Scans running processes using `ps aux` to detect active Claude CLI instances and related subprocesses.
- **Agent detection via /tmp task output files**: Identifies Claude agents by reading task output files written to `/tmp`, enabling visibility into agent activity beyond raw process data.
- **Session naming with cs command**: Allows users to assign human-readable names to Claude sessions using the `cs` command, making it easier to track multiple concurrent sessions.
- **Process to Agent tree view**: Displays a hierarchical tree that maps OS processes to their corresponding Claude agents, giving a clear parent-child relationship view in the UI.
- **Conversation history reading from ~/.claude/projects/**: Reads local conversation history stored under `~/.claude/projects/` to surface session context and message summaries alongside live process data.
- **Running/completed status detection**: Distinguishes between actively running and already completed Claude sessions, keeping the monitor view accurate without manual refresh.
- **Kill process from UI**: Provides an in-UI action to send a kill signal to any listed Claude process, allowing users to terminate sessions without leaving the monitor.
- **Auto-refresh every 5s**: Automatically polls and refreshes all process and agent data every 5 seconds so the displayed state stays current without user intervention.
