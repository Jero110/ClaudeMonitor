#!/usr/bin/env zsh
# Claude Monitor — start script
# Usage: bash start.sh  OR  zsh start.sh

MONITOR_DIR="$(cd "$(dirname "$0")" && pwd)"

# Kill any leftover processes
pkill -9 -f "claude-monitor.sh" 2>/dev/null
pkill -9 -f "python3.*7337" 2>/dev/null
lsof -ti tcp:7337 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 0.3

# Trap Ctrl+C to kill cleanly
trap 'echo "\nStopping monitor…"; pkill -9 -f "claude-monitor.sh" 2>/dev/null; pkill -9 -f "python3.*7337" 2>/dev/null; lsof -ti tcp:7337 2>/dev/null | xargs kill -9 2>/dev/null; exit 0' INT QUIT

echo "Starting claude monitor… (Ctrl+C to stop)"

zsh "$MONITOR_DIR/claude-monitor.sh" &
SERVER_PID=$!

# Wait for server to be ready
tries=0
while ! curl -s http://localhost:7337/data > /dev/null 2>&1; do
  sleep 0.5
  tries=$((tries+1))
  if [ $tries -gt 20 ]; then
    echo "Failed to start. Check logs."
    pkill -9 -f "claude-monitor.sh" 2>/dev/null
    exit 1
  fi
done

echo "Ready → http://localhost:7337"

# Open browser (macOS)
if command -v open &>/dev/null; then
  open "$MONITOR_DIR/claude-monitor.html"
# Linux fallback
elif command -v xdg-open &>/dev/null; then
  xdg-open "$MONITOR_DIR/claude-monitor.html"
fi

wait $SERVER_PID
