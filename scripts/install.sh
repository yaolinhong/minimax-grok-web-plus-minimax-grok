#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer currently supports macOS only." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js 18+ is required. Please install Node.js first." >&2
  exit 1
fi

node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if (( node_major < 18 )); then
  echo "Node.js 18+ is required. Current version: $(node -v)" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_dir="${HOME}/.claude/system-user-shim"
settings_file="${HOME}/.claude/settings.json"
launch_agents_dir="${HOME}/Library/LaunchAgents"
label="com.claude-code.system-user-shim"
plist_file="${launch_agents_dir}/${label}.plist"
log_file="${HOME}/.claude/logs/system-user-shim.log"
state_file="${install_dir}/state.json"

default_model="MiniMax-M2.7-highspeed"
default_target="https://api.minimaxi.com/anthropic"
default_port="17861"
default_pattern="minimax"

echo "Claude Code System-User Shim installer"
echo

read -rsp "MiniMax API Key: " api_key
echo
if [[ -z "${api_key}" ]]; then
  echo "API Key cannot be empty." >&2
  exit 1
fi

echo
echo "Select model:"
select model in "MiniMax-M2.7-highspeed" "MiniMax-M2.7" "Custom"; do
  case "${model}" in
    "Custom")
      read -rp "Enter custom model name: " custom_model
      if [[ -z "${custom_model}" ]]; then
        echo "Model name cannot be empty." >&2
        exit 1
      fi
      model="${custom_model}"
      ;;
    "")
      echo "Invalid selection." >&2
      exit 1
      ;;
  esac
  break
done

read -rp "MiniMax Anthropic base URL [${default_target}]: " target_base_url
target_base_url="${target_base_url:-$default_target}"

read -rp "Local shim port [${default_port}]: " port
port="${port:-$default_port}"

read -rp "Model match pattern [${default_pattern}]: " model_pattern
model_pattern="${model_pattern:-$default_pattern}"

mkdir -p "${install_dir}" "${launch_agents_dir}" "${HOME}/.claude/logs"
cp "${repo_root}/server.mjs" "${install_dir}/server.mjs"
chmod +x "${install_dir}/server.mjs"

node_path="$(command -v node)"

cat >"${plist_file}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${node_path}</string>
    <string>${install_dir}/server.mjs</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>SYSTEM_USER_SHIM_PORT</key>
    <string>${port}</string>
    <key>SYSTEM_USER_SHIM_TARGET_BASE_URL</key>
    <string>${target_base_url}</string>
    <key>SYSTEM_USER_SHIM_MODEL_PATTERN</key>
    <string>${model_pattern}</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${log_file}</string>
  <key>StandardErrorPath</key>
  <string>${log_file}</string>
</dict>
</plist>
PLIST

plutil -lint "${plist_file}" >/dev/null

export SHIM_SETTINGS_FILE="${settings_file}"
export SHIM_STATE_FILE="${state_file}"
export SHIM_API_KEY="${api_key}"
export SHIM_MODEL="${model}"
export SHIM_TARGET_BASE_URL="${target_base_url}"
export SHIM_PORT="${port}"
export SHIM_MODEL_PATTERN="${model_pattern}"
export SHIM_LABEL="${label}"
export SHIM_PLIST="${plist_file}"

node <<'NODE'
const fs = require("fs");
const path = require("path");

const settingsFile = process.env.SHIM_SETTINGS_FILE;
const stateFile = process.env.SHIM_STATE_FILE;
fs.mkdirSync(path.dirname(settingsFile), { recursive: true });

let settings = {};
if (fs.existsSync(settingsFile)) {
  settings = JSON.parse(fs.readFileSync(settingsFile, "utf8"));
}

const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const backupFile = `${settingsFile}.system-user-shim.${timestamp}.bak`;
if (fs.existsSync(settingsFile)) {
  fs.copyFileSync(settingsFile, backupFile);
}

settings.env = settings.env && typeof settings.env === "object" ? settings.env : {};
Object.assign(settings.env, {
  ANTHROPIC_BASE_URL: `http://127.0.0.1:${process.env.SHIM_PORT}`,
  ANTHROPIC_AUTH_TOKEN: process.env.SHIM_API_KEY,
  SYSTEM_USER_SHIM_TARGET_BASE_URL: process.env.SHIM_TARGET_BASE_URL,
  SYSTEM_USER_SHIM_MODEL_PATTERN: process.env.SHIM_MODEL_PATTERN,
  ANTHROPIC_MODEL: process.env.SHIM_MODEL,
  ANTHROPIC_SMALL_FAST_MODEL: process.env.SHIM_MODEL,
  ANTHROPIC_DEFAULT_SONNET_MODEL: process.env.SHIM_MODEL,
  ANTHROPIC_DEFAULT_OPUS_MODEL: process.env.SHIM_MODEL,
  ANTHROPIC_DEFAULT_HAIKU_MODEL: process.env.SHIM_MODEL,
});

if (!settings.env.API_TIMEOUT_MS) {
  settings.env.API_TIMEOUT_MS = "3000000";
}
if (!settings.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) {
  settings.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
}

fs.writeFileSync(settingsFile, `${JSON.stringify(settings, null, 2)}\n`);
fs.writeFileSync(
  stateFile,
  `${JSON.stringify(
    {
      installedAt: new Date().toISOString(),
      settingsFile,
      backupFile: fs.existsSync(backupFile) ? backupFile : null,
      label: process.env.SHIM_LABEL,
      plistFile: process.env.SHIM_PLIST,
      port: process.env.SHIM_PORT,
      targetBaseUrl: process.env.SHIM_TARGET_BASE_URL,
      modelPattern: process.env.SHIM_MODEL_PATTERN,
      model: process.env.SHIM_MODEL,
    },
    null,
    2,
  )}\n`,
);
NODE

/bin/launchctl bootout "gui/$UID/${label}" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$UID" "${plist_file}" >/dev/null 2>&1 || true
/bin/launchctl kickstart -k "gui/$UID/${label}" >/dev/null 2>&1 || true

for _ in {1..30}; do
  if /usr/bin/curl -fsS "http://127.0.0.1:${port}/__health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! /usr/bin/curl -fsS "http://127.0.0.1:${port}/__health" >/dev/null 2>&1; then
  echo "system-user-shim failed to start on port ${port}" >&2
  exit 1
fi

echo
echo "Installed."
echo "Health: http://127.0.0.1:${port}/__health"
echo "Claude Code settings: ${settings_file}"
echo "LaunchAgent: ${plist_file}"
