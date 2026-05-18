#!/usr/bin/env bash
set -euo pipefail

install_dir="${HOME}/.claude/system-user-shim"
state_file="${install_dir}/state.json"
default_label="com.claude-code.system-user-shim"
default_plist="${HOME}/Library/LaunchAgents/${default_label}.plist"
legacy_label="com.linhongyao.claude-system-user-shim"
legacy_plist="${HOME}/Library/LaunchAgents/${legacy_label}.plist"

label="${default_label}"
plist_file="${default_plist}"
settings_file="${HOME}/.claude/settings.json"
backup_file=""

if [[ -f "${state_file}" ]]; then
  label="$(node -e 'const s=require(process.argv[1]); console.log(s.label || "")' "${state_file}")"
  plist_file="$(node -e 'const s=require(process.argv[1]); console.log(s.plistFile || "")' "${state_file}")"
  settings_file="$(node -e 'const s=require(process.argv[1]); console.log(s.settingsFile || "")' "${state_file}")"
  backup_file="$(node -e 'const s=require(process.argv[1]); console.log(s.backupFile || "")' "${state_file}")"
fi

label="${label:-$default_label}"
plist_file="${plist_file:-$default_plist}"

/bin/launchctl bootout "gui/$UID/${label}" >/dev/null 2>&1 || true
rm -f "${plist_file}"

if [[ "${label}" != "${legacy_label}" ]]; then
  /bin/launchctl bootout "gui/$UID/${legacy_label}" >/dev/null 2>&1 || true
  rm -f "${legacy_plist}"
fi

if [[ -n "${backup_file}" && -f "${backup_file}" ]]; then
  read -rp "Restore Claude Code settings backup? [y/N]: " restore
  if [[ "${restore}" =~ ^[Yy]$ ]]; then
    cp "${backup_file}" "${settings_file}"
    echo "Restored ${settings_file} from ${backup_file}"
  else
    echo "Skipped settings restore. Backup remains at ${backup_file}"
  fi
else
  echo "No settings backup found."
fi

rm -rf "${install_dir}"
echo "Uninstalled system-user-shim."
