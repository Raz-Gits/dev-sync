#!/usr/bin/env bash
#
# monitor-notify.sh - scheduled wrapper around monitor.sh.
#
# Runs the sweep, appends the report to a log, and - when something needs
# attention - raises a desktop notification. Quiet exit when healthy.
#
# macOS: notification via osascript; log in ~/Library/Logs/devsync-monitor.log
# Windows (Git Bash): log only, at ~/devsync-monitor.log - wire Task Scheduler
# to run this and add a toast there if wanted.
#
# Scheduling (Mac): ~/Library/LaunchAgents/com.razsela.devsync-monitor.plist

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
  Darwin*) OS=mac;     LOG="${DEVSYNC_MONITOR_LOG:-$HOME/Library/Logs/devsync-monitor.log}" ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows; LOG="${DEVSYNC_MONITOR_LOG:-$HOME/devsync-monitor.log}" ;;
  *) OS=other;         LOG="${DEVSYNC_MONITOR_LOG:-$HOME/devsync-monitor.log}" ;;
esac
mkdir -p "$(dirname "$LOG")"

report="$(bash "$HERE/monitor.sh" "${1:-$HOME}" 2>&1)"
status=$?

# Log without ANSI colors, newest entry last; keep the file from growing forever.
esc="$(printf '\033')"
clean="$(printf '%s\n' "$report" | sed "s/${esc}\[[0-9;]*m//g")"
{
  printf '=== devsync monitor  %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n\n' "$clean"
} >> "$LOG"
tail -n 600 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

if [ "$status" -eq 1 ]; then
  summary="$(printf '%s\n' "$clean" | grep -E 'need attention|NO AGE KEY' | tail -1)"
  [ -n "$summary" ] || summary="bridge needs attention"
  if [ "$OS" = "mac" ]; then
    osascript -e "display notification \"${summary} Report: ~/Library/Logs/devsync-monitor.log\" with title \"devsync monitor\" sound name \"Ping\"" 2>/dev/null || true
  fi
fi

exit "$status"
