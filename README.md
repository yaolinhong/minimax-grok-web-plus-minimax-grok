# Claude Code System-User Shim

让 Claude Code 使用 MiniMax 这类对 `system` 指令不敏感的 Anthropic 兼容模型时，把请求里的 `system` 字段改写成第一条 `user` 消息。

这个工具不会重复追加 system prompt。它是在 HTTP 请求转发层做一次性改写：

```text
Claude Code -> local shim -> MiniMax Anthropic API
```

## 解决的问题

Claude Code 发送 Anthropic 协议请求时，核心规则通常在请求体的 `system` 字段里。部分模型对 `system` 遵循较差时，会出现“同样的规则作为 user 输入效果明显更好”的现象。

本 shim 在转发前执行：

```text
body.system -> body.messages[0].role = "user"
delete body.system
```

默认只对模型名匹配 `minimax` 的请求生效。

## 一键安装

```bash
git clone https://github.com/YOUR_NAME/claude-system-user-shim.git
cd claude-system-user-shim
./scripts/install.sh
```

把上面的仓库地址替换成你自己的 GitHub 仓库地址。

安装脚本会交互式询问：

- MiniMax API Key
- 模型名，默认 `MiniMax-M2.7-highspeed`
- MiniMax Anthropic API 地址，默认 `https://api.minimaxi.com/anthropic`
- 本地端口，默认 `17861`
- 模型匹配规则，默认 `minimax`

API Key 只会写入本机 `~/.claude/settings.json`，不会进入仓库。

## 安装后行为

安装器会：

- 备份 `~/.claude/settings.json`
- 安装 shim 到 `~/.claude/system-user-shim`
- 写入 macOS 用户级 LaunchAgent
- 将 Claude Code 的 `ANTHROPIC_BASE_URL` 设置为 `http://127.0.0.1:17861`
- 添加一个 `SessionStart` hook，只负责确保 shim 服务已启动，不注入任何 prompt

健康检查：

```bash
curl http://127.0.0.1:17861/__health
```

返回 `ok` 即正常。

## 卸载

```bash
./scripts/uninstall.sh
```

卸载脚本会停止 LaunchAgent，删除本机 shim 文件，并询问是否恢复安装时备份的 `settings.json`。

## 平台

当前安装脚本支持 macOS，因为 Claude Code 的本机常驻服务使用 `launchctl` 管理。shim 服务本身是 Node.js 单文件，后续可以扩展 Linux systemd 用户服务。

## 要求

- macOS
- Node.js 18+
- Claude Code

## 安全说明

- 本服务只监听 `127.0.0.1`
- API Key 保存在本机 Claude Code 配置中
- shim 不记录请求体
- shim 不修改非 JSON 请求
- 默认只改写模型名匹配 `minimax` 的请求
