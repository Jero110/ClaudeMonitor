# Claude Monitor - Troubleshooting Guide

## Monitor Won't Start

**Port already in use**

The monitor runs a Python HTTP server on port 7337. If another process is already using
that port, startup will fail silently or error out.

Check what is using the port:

```sh
lsof -i :7337
```

Kill the occupying process or change the PORT variable at the top of `claude-monitor.sh`
before starting.

**Path issues / script not found**

The Python server hard-codes the working directory to
`~/Desktop/other/Vs/ClaudeMonitor` (line 425 of the script). If you have moved the
repo to a different location you must update that `os.chdir(...)` call to match.

Also confirm the script is executable:

```sh
chmod +x claude-monitor.sh
```

---

## No Processes Showing

The script collects processes with:

```sh
ps aux | grep -E "(^| )claude( |$|/)" | grep -v grep | grep -v "claude-monitor" | grep -v "zsh.*claude"
```

This only matches processes whose command contains the word `claude` as a standalone
token (space or path boundary on both sides). Processes launched under a different binary
name, through a wrapper, or whose command line does not contain the literal string
`claude` will be invisible to the monitor.

Common causes:

- Claude is installed under a non-standard binary name or path.
- The process was started by a parent shell that itself matches `zsh.*claude`, causing it
  to be excluded by the third filter.
- `ps aux` output is truncated on your system -- check `ps auxww` to see full command
  lines.

---

## Agents Show as Completed When Still Running

Agent status is determined by comparing the agent's `sessionId` (read from its `.output`
file in `/tmp/claude-*/*/tasks/`) against the list of session IDs found in currently
running `claude` processes.

An agent will be incorrectly shown as `completed` if:

- The session ID is missing from the `.output` file (no `sessionId` field written yet,
  or the output file is very new).
- The running process command line does not contain a recognisable UUID, so it never
  appears in the `active_sessions` list.
- macOS `/tmp` is actually `/private/tmp` -- the script searches both, but if your
  system uses a different temp path the output files will not be found at all.

Workaround: wait a few seconds for more output to be written to the task file, then
refresh the browser.

---

## Session Names Not Showing

Session names are read from `~/.claude/session-names.json`. The file maps a human name
to an object containing an `id` field (the UUID).

Check the file exists and is valid JSON:

```sh
python3 -m json.tool ~/.claude/session-names.json
```

If the file is absent, no names will resolve and the `sessionName` field will be empty
-- this is normal when Claude Code has not written any named sessions yet.

If names exist in the file but still do not appear, confirm that the session UUID in the
running process command line or agent output exactly matches the `id` value in the JSON.

---

## Browser Shows "Failed to Fetch"

The HTML file (`claude-monitor.html`) fetches data from `http://localhost:7337/data`.

Things to verify:

1. The monitor script is actually running (`ps aux | grep claude-monitor`).
2. You opened `claude-monitor.html` directly from the filesystem (a `file://` URL).
   Modern browsers allow `file://` pages to fetch `localhost` -- but some strict
   security settings block this. Try opening the file in a different browser or disable
   the relevant content-security policy.
3. The Python server may have crashed after startup. Restart the script and watch for
   Python error output in the terminal.
4. On macOS, a firewall rule or Little Snitch policy may be blocking loopback
   connections on port 7337 -- check your firewall settings.
