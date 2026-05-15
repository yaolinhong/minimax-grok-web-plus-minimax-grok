#!/usr/bin/env bash
set -euo pipefail

port="${SYSTEM_USER_SHIM_PORT:-17861}"
label="${SYSTEM_USER_SHIM_LABEL:-com.claude-code.system-user-shim}"
plist="${SYSTEM_USER_SHIM_PLIST:-${HOME}/Library/LaunchAgents/${label}.plist}"

if /usr/bin/curl -fsS "http://127.0.0.1:${port}/__health" >/dev/null 2>&1; then
  exit 0
fi

/bin/launchctl bootstrap "gui/$UID" "${plist}" >/dev/null 2>&1 || true
/bin/launchctl kickstart -k "gui/$UID/${label}" >/dev/null 2>&1 || true

for _ in {1..30}; do
  if /usr/bin/curl -fsS "http://127.0.0.1:${port}/__health" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.1
done

echo "system-user-shim failed to start on port ${port}" >&2
exit 1
