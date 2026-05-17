# Findings

## Context
- User-reported symptom: Claude Code uses `/goal` and gets `api400`.
- Analysis mode used. No business code changes were made.
- Repository under review: `/Users/linhongyao/data/code/github/claude-system-user-shim`

## High-confidence conclusions

### 1. The repo itself does **not** implement `/goal` compatibility
Evidence:
- Core proxy logic in [server.mjs](/Users/linhongyao/data/code/github/claude-system-user-shim/server.mjs:73) is generic request forwarding only.
- It only:
  - rewrites `system -> first user message` for matching models at [server.mjs](/Users/linhongyao/data/code/github/claude-system-user-shim/server.mjs:30)
  - forwards request path as-is to upstream at [server.mjs](/Users/linhongyao/data/code/github/claude-system-user-shim/server.mjs:81)
- There is no branch for `/v1/eval_hook`, `/goal`, `goal evaluator`, or any special request-shape adaptation in the repo version.

Implication:
- If Claude Code `/goal` issues any non-standard Anthropic-compatible request, this repo version will blindly forward it to MiniMax.
- Therefore compatibility depends entirely on whether MiniMax already supports that exact request shape.

### 2. The installer forces **all model roles** onto the same third-party model
Evidence:
- Install script writes the same model into:
  - `ANTHROPIC_MODEL`
  - `ANTHROPIC_SMALL_FAST_MODEL`
  - `ANTHROPIC_DEFAULT_SONNET_MODEL`
  - `ANTHROPIC_DEFAULT_OPUS_MODEL`
  - `ANTHROPIC_DEFAULT_HAIKU_MODEL`
  at [scripts/install.sh](/Users/linhongyao/data/code/github/claude-system-user-shim/scripts/install.sh:149).
- Your local config confirms this happened in [settings.json](/Users/linhongyao/.claude/settings.json:2).

Implication:
- Claude Code internal subflows that expect a different capability profile for the “small fast” model are also forced onto `MiniMax-M2.7-highspeed`.
- `/goal` is especially suspicious because the Claude Code binary contains explicit `goal`/`active_goal`/`goal_status` codepaths and also references `ANTHROPIC_SMALL_FAST_MODEL` plus `claude-haiku-4-5` strings.
- This makes it very likely that `/goal` triggers an internal evaluator path that assumes Anthropic-native behavior or request schema.

### 3. The observed 400 is from the upstream provider, not from the shim's generic error handler
Evidence:
- Local runtime log `~/.claude/logs/system-user-shim.log` shows repeated upstream responses:
  - `400 error ... {"type":"error","error":{"type":"invalid_request_error","message":"invalid params"}}`
- So the proxy successfully forwards the request, but MiniMax rejects the forwarded payload.

Implication:
- Root cause is request-shape incompatibility with upstream, not network failure and not local JSON parsing failure.

### 4. Your machine is currently running a **different local patched shim**, not the repo version
Evidence:
- `cmp -s server.mjs ~/.claude/system-user-shim/server.mjs` returned different files.
- The installed runtime file contains custom logic not present in the repo, including:
  - route-based upstream selection
  - debug logging
  - `/v1/eval_hook` handling
  - retry logic
- The repo `server.mjs` does not contain these behaviors.

Implication:
- There are two layers of truth:
  1. repo design problem: no native `/goal` compatibility strategy
  2. local patched runtime still incomplete: even with ad-hoc `/v1/eval_hook` handling, upstream still returns `400 invalid params`

## Strong hypothesis for why `/goal` breaks

### Hypothesis A: `/goal` uses an internal eval/evaluator request shape not supported by MiniMax Anthropic compatibility
Supporting evidence:
- Claude Code binary contains goal-related strings such as:
  - `/goal is only available in trusted workspaces...`
  - `goalNonInteractive`
  - `active_goal`
  - `goal_status`
  - `goal_set`
  - `goal_met`
- The binary also contains the string:
  - `expected 'true' or 'false', falling back to 'false' (default)`
- This strongly suggests `/goal` has a machine-evaluable subrequest, likely expecting a narrow boolean-like response contract.
- Your local patched shim already added a `/v1/eval_hook` compatibility branch, which is a further clue that `/goal` is not a plain `/v1/messages` happy path.

Assessment:
- Very likely true.

### Hypothesis B: `/goal` may depend on preserving `system`, while this project’s core behavior deletes `system`
Supporting evidence:
- Repo default behavior is to move `system` into a user message and set `system: undefined` at [server.mjs](/Users/linhongyao/data/code/github/claude-system-user-shim/server.mjs:39).
- Some evaluator-style prompts can be schema-sensitive and may rely on `system` semantics more than ordinary chat.

Counterpoint:
- Your local installed shim already appears to have a `PRESERVE_SYSTEM` mechanism in the repo working tree, and the live 400s still occur.
- The upstream error says `invalid params`, which sounds more like payload schema rejection than poor model behavior.

Assessment:
- Possible contributing factor, but probably not the primary one.

### Hypothesis C: the provider rejects certain tool/beta/request combinations used during `/goal`
Supporting evidence:
- Logs show failing requests sometimes have `tools:40`, sometimes `tools:0`, all against `/v1/messages?beta=true`.
- This suggests Claude Code can emit multiple request shapes during a `/goal` workflow, and at least one of them is not accepted by MiniMax.
- Because the shim preserves query string/path generically, any unsupported `beta` semantics are passed through unchanged.

Assessment:
- Also very likely.

## Why this repository design causes the problem

### Design issue 1: Assumes “Anthropic-compatible” means “compatible with all Claude Code internal traffic”
But Claude Code `/goal` is not just a normal chat turn. The repo has no compatibility matrix or endpoint adaptation layer.

### Design issue 2: Treats all model roles as one interchangeable model
This is fine for basic chatting, but unsafe for internal Claude Code features that may use:
- different prompt contracts
- different response parsers
- evaluator subrequests
- stricter schema expectations

### Design issue 3: No allowlist/transform layer per endpoint
The repo forwards everything under the configured base URL. If Claude Code later adds new endpoints or new special message fields, the shim has no validation or normalization strategy.

## Blind spots
- I did not decode the full Claude Code binary control flow to prove the exact HTTP body of `/goal` requests end-to-end.
- I do not yet have a raw captured `/goal` request body from your machine for the exact failing turn.
- Because the installed runtime is already locally patched, I cannot attribute the current failure to the repo version alone without separating those local modifications.

## Practical root-cause statement
Most likely root cause:
- `/goal` triggers a Claude Code internal evaluator/request path that MiniMax’s Anthropic-compatible endpoint does not fully support.
- This repo magnifies the issue by forcing every model role, including `ANTHROPIC_SMALL_FAST_MODEL`, onto the same third-party model and by forwarding all JSON request shapes without endpoint-specific adaptation.
- Result: upstream returns `400 invalid params`, which Claude Code surfaces as `api400`.

## Suggested next verification steps
1. Add request-body logging for only failing `/v1/messages?beta=true` 400 responses, with secrets redacted.
2. Capture whether `/goal` actually calls `/v1/eval_hook` or sends a special `/v1/messages` payload on this version of Claude Code.
3. Temporarily set `ANTHROPIC_SMALL_FAST_MODEL` back to a native Anthropic model or another known-compatible provider while keeping the main model on MiniMax, then retest `/goal`.
4. If `/goal` succeeds after step 3, the installer’s “single-model-for-all-roles” strategy is confirmed as the direct trigger.
