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

# Security sweep: new secrets in any repo, credential files lying around,
# GitHub visibility/Dependabot changes. It writes the vault's Security report;
# non-zero means something new needs a look.
sec="$(bash "$HERE/devsync.sh" secscan 2>&1)"
sec_status=$?
report="${report}

${sec}"
# 1 = something new needs a look; 3 = skipped (tooling missing on this machine).
[ "$sec_status" -eq 1 ] && [ "$status" -eq 0 ] && status=1

# Log without ANSI colors, newest entry last; keep the file from growing forever.
esc="$(printf '\033')"
clean="$(printf '%s\n' "$report" | sed "s/${esc}\[[0-9;]*m//g")"
{
  printf '=== devsync monitor  %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n\n' "$clean"
} >> "$LOG"
tail -n 600 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

if [ "$status" -eq 1 ]; then
  summary="$(printf '%s\n' "$clean" | grep -E 'need attention|NO AGE KEY|PUBLIC repo' \
             | sed 's/^secscan: //' | tr '\n' ' ' | sed 's/ *$//')"
  [ -n "$summary" ] || summary="bridge needs attention"
  if [ "$OS" = "mac" ]; then
    osascript -e "display notification \"${summary} Report: ~/Library/Logs/devsync-monitor.log\" with title \"devsync monitor\" sound name \"Ping\"" 2>/dev/null || true
  elif [ "$OS" = "windows" ]; then
    # Balloon tip via NotifyIcon: works on a stock Windows box with no extra
    # PowerShell modules (BurntToast and friends are not installed by default).
    # Backgrounded and fully swallowed - a missing notification must never turn
    # a healthy sweep into a failed scheduled task.
    _msg="$(printf '%s' "$summary" | sed "s/'/''/g")"
    powershell -NoProfile -NonInteractive -Command "
      Add-Type -AssemblyName System.Windows.Forms;
      Add-Type -AssemblyName System.Drawing;
      \$n = New-Object System.Windows.Forms.NotifyIcon;
      \$n.Icon = [System.Drawing.SystemIcons]::Warning;
      \$n.BalloonTipTitle = 'devsync monitor';
      \$n.BalloonTipText = '${_msg}. See ~/devsync-monitor.log';
      \$n.Visible = \$true;
      \$n.ShowBalloonTip(15000);
      Start-Sleep -Seconds 16;
      \$n.Dispose();
    " >/dev/null 2>&1 &
  fi
fi

exit "$status"
