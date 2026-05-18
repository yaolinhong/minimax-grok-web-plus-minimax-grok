#!/usr/bin/env node
import http from "node:http";
import https from "node:https";
import { URL } from "node:url";

const port = Number(process.env.SYSTEM_USER_SHIM_PORT || 17861);
const targetBaseUrl = process.env.SYSTEM_USER_SHIM_TARGET_BASE_URL;
const modelPattern = new RegExp(process.env.SYSTEM_USER_SHIM_MODEL_PATTERN || "minimax", "i");
const preserveSystemPatterns = (process.env.SYSTEM_USER_SHIM_PRESERVE_SYSTEM || "")
  .split(",")
  .map((pattern) => pattern.trim())
  .filter(Boolean)
  .map((pattern) => new RegExp(pattern, "i"));
const unsupportedTopLevelKeys = [
  "container",
  "context_management",
  "mcp_servers",
  "output_config",
  "service_tier",
  "thinking",
];
const stopHookJsonInstruction = [
  "You are evaluating whether a Claude Code stop condition is satisfied.",
  "Use only the transcript evidence provided below.",
  "Do not explain your reasoning before the JSON.",
  "Return exactly one JSON object and no other text.",
  "Schema: {\"ok\": boolean, \"reason\": string}",
  "Keep reason concise, under 80 words.",
  "Use ok=true only when the evidence shows the condition has already been satisfied.",
  "Use ok=false when the evidence is missing, ambiguous, or only says work will start.",
].join("\n");

if (!targetBaseUrl) {
  console.error("SYSTEM_USER_SHIM_TARGET_BASE_URL is required");
  process.exit(1);
}

function normalizeContent(content) {
  if (Array.isArray(content)) return content;
  if (typeof content === "string") {
    return [{ type: "text", text: content }];
  }
  return [{ type: "text", text: String(content) }];
}

function safeStringify(value) {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function flattenContentToText(content) {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return content == null ? "" : String(content);
  }

  return content
    .map((block) => {
      if (typeof block === "string") {
        return block;
      }
      if (block?.type === "text" && typeof block.text === "string") {
        return block.text;
      }
      if (block?.type === "tool_use") {
        return [`tool_use: ${String(block.name || "")}`, `input: ${safeStringify(block.input || {})}`].join("\n");
      }
      if (block?.type === "tool_result") {
        const resultText = flattenContentToText(block.content);
        return [`tool_result: ${resultText}`, block.is_error === true ? "is_error: true" : ""].filter(Boolean).join("\n");
      }
      return "";
    })
    .join("\n");
}

function flattenMessagesToText(messages) {
  if (!Array.isArray(messages)) {
    return "";
  }

  return messages
    .map((message) => {
      const role = typeof message?.role === "string" ? message.role : "message";
      return `${role}: ${flattenContentToText(message?.content)}`;
    })
    .join("\n\n");
}

function matchesPatterns(text, patterns) {
  return patterns.some((pattern) => pattern.test(text));
}

function shouldPreserveSystem(body) {
  const systemText = flattenContentToText(body?.system).trim();
  if (!systemText) return false;
  return matchesPatterns(systemText, preserveSystemPatterns);
}

function sanitizeContent(content) {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return content;
  }

  return content
    .map((block) => sanitizeContentBlock(block))
    .filter((block) => block !== null);
}

function sanitizeContentBlock(block) {
  if (block == null) {
    return null;
  }
  if (typeof block === "string") {
    return { type: "text", text: block };
  }
  if (typeof block !== "object") {
    return { type: "text", text: String(block) };
  }

  switch (block.type) {
    case "text":
      return {
        type: "text",
        text: typeof block.text === "string" ? block.text : String(block.text ?? ""),
      };
    case "tool_use":
      if (!block.id || !block.name) {
        return null;
      }
      return {
        type: "tool_use",
        id: String(block.id),
        name: String(block.name),
        input: block.input && typeof block.input === "object" ? block.input : {},
      };
    case "tool_result": {
      const sanitized = {
        type: "tool_result",
        tool_use_id: String(block.tool_use_id || ""),
        content: sanitizeContent(block.content),
      };
      if (!sanitized.tool_use_id) {
        return null;
      }
      if (block.is_error === true) {
        sanitized.is_error = true;
      }
      return sanitized;
    }
    default: {
      const sanitized = { ...block };
      delete sanitized.cache_control;
      delete sanitized.citations;
      return sanitized;
    }
  }
}

function sanitizeMessage(message) {
  if (!message || typeof message !== "object") {
    return message;
  }

  return {
    ...message,
    content: sanitizeContent(message.content),
  };
}

function sanitizeTool(tool) {
  if (!tool || typeof tool !== "object") {
    return null;
  }

  const name = typeof tool.name === "string" ? tool.name.trim() : "";
  if (!name) {
    return null;
  }

  const sanitized = { name };
  if (typeof tool.description === "string" && tool.description.trim()) {
    sanitized.description = tool.description;
  }
  if (tool.input_schema && typeof tool.input_schema === "object") {
    sanitized.input_schema = tool.input_schema;
  }
  return sanitized;
}

function isStopHookEvaluatorRequest(body) {
  const systemText = flattenContentToText(body?.system);
  const messagesText = flattenMessagesToText(body?.messages);
  const text = `${systemText}\n${messagesText}`;
  const args = extractStopHookArguments(text);
  const hasStopHookArgs =
    /hook_event_name/i.test(text) &&
    /Stop/i.test(String(args?.hook_event_name || text)) &&
    (/last_assistant_message/i.test(text) || /transcript_path/i.test(text) || /stop_hook_active/i.test(text));
  const hasGoalStopPrompt =
    /stopping condition/i.test(text) &&
    (/satisfied/i.test(text) || /met/i.test(text) || /achieved/i.test(text) || /fulfilled/i.test(text)) &&
    (/transcript/i.test(text) || /conversation/i.test(text) || /last_assistant_message/i.test(text));

  return (
    /Based on the conversation transcript above, has the following stopping condition been satisfied\?/i.test(text) ||
    hasStopHookArgs ||
    hasGoalStopPrompt
  );
}

function extractStopHookArguments(text) {
  return extractJsonObjectAfterMarker(text, "ARGUMENTS:") || extractJsonObjectAfterMarker(text, "Arguments:") || extractJsonObjectAfterMarker(text, "arguments:");
}

function extractJsonObjectAfterMarker(text, marker) {
  const markerIndex = text.indexOf(marker);
  if (markerIndex === -1) {
    return undefined;
  }

  const start = text.indexOf("{", markerIndex + marker.length);
  if (start === -1) {
    return undefined;
  }

  let depth = 0;
  let inString = false;
  let escape = false;
  for (let index = start; index < text.length; index += 1) {
    const char = text[index];
    if (escape) {
      escape = false;
      continue;
    }
    if (char === "\\") {
      escape = true;
      continue;
    }
    if (char === "\"") {
      inString = !inString;
      continue;
    }
    if (inString) {
      continue;
    }
    if (char === "{") {
      depth += 1;
    } else if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        try {
          return JSON.parse(text.slice(start, index + 1));
        } catch {
          return undefined;
        }
      }
    }
  }

  return undefined;
}

function extractStopHookEvaluatorParts(body) {
  const messages = Array.isArray(body?.messages) ? body.messages : [];
  const text = `${flattenContentToText(body?.system)}\n${flattenMessagesToText(messages)}`;
  const hookMessageIndex = messages.findLastIndex((message) => {
    const contentText = flattenContentToText(message?.content);
    return /Based on the conversation transcript above, has the following stopping condition been satisfied\?/i.test(contentText) || /ARGUMENTS:\s*\{/i.test(contentText);
  });
  const evidenceMessages = hookMessageIndex === -1 ? messages : messages.slice(0, hookMessageIndex);
  const conditionMatches = [...text.matchAll(/^Condition:\s*([^\n]+)/gim)];
  const conditionMatch = conditionMatches.at(-1);
  const args = extractStopHookArguments(text);
  return {
    condition: String(conditionMatch?.[1] || "").trim(),
    lastAssistantMessage: typeof args?.last_assistant_message === "string" ? args.last_assistant_message : "",
    evidenceText: flattenMessagesToText(evidenceMessages),
    rawText: text,
  };
}

function truncateMiddle(text, maxLength) {
  const value = String(text || "");
  if (value.length <= maxLength) {
    return value;
  }

  const headLength = Math.floor(maxLength * 0.35);
  const tailLength = maxLength - headLength;
  return `${value.slice(0, headLength)}\n\n...[truncated ${value.length - maxLength} chars]...\n\n${value.slice(-tailLength)}`;
}

function compactTranscriptEvidence(evidenceText) {
  const text = String(evidenceText || "");
  const lines = text.split("\n");
  const importantPattern =
    /goal|condition|完成|最终|证据|交付|需求|状态|已创建|已实现|已包含|已集成|已验证|可运行|正常工作|clean|nothing to commit|working tree|git |commit|README|readme|src\/|examples\/|package\.json|\.gitignore|skill|技术博客写作|git-commit|tool_use|tool_result|Bash|Write|Update|Read|mkdir|npm|publish|自动化|公众号|微信|仓库|脚本|CLI|api\.js|cli\.js/i;
  const important = lines.filter((line) => importantPattern.test(line));
  const head = lines.slice(0, 40);
  const tail = lines.slice(-180);
  const joined = [...head, "", "[important transcript lines]", ...important.slice(-260), "", "[recent transcript tail]", ...tail].join("\n");
  return truncateMiddle(joined, 12000);
}

function compactStopHookEvaluatorRequest(body) {
  const { condition, lastAssistantMessage, evidenceText } = extractStopHookEvaluatorParts(body);
  const evidence = compactTranscriptEvidence(evidenceText || lastAssistantMessage);
  const prompt = [
    stopHookJsonInstruction,
    "",
    `Condition: ${condition || "(missing)"}`,
    "",
    "Last assistant message:",
    lastAssistantMessage || "(missing)",
    "",
    "Conversation transcript evidence:",
    evidence,
    "",
    "Return exactly JSON now.",
  ].join("\n");

  const compacted = { ...body };
  compacted.max_tokens = Math.min(Math.max(Number(body.max_tokens || 1024) || 1024, 512), 2048);
  compacted.stream = false;
  compacted.temperature = 0;
  compacted.messages = [
    {
      role: "user",
      content: [{ type: "text", text: prompt }],
    },
  ];

  delete compacted.system;
  delete compacted.tools;
  delete compacted.tool_choice;
  delete compacted.metadata;
  delete compacted.output_config;
  delete compacted.stop_sequences;

  return compacted;
}

function createAnthropicMessage(model, text) {
  return {
    id: `msg_${Date.now().toString(36)}`,
    type: "message",
    role: "assistant",
    model: String(model || "system-user-shim"),
    content: [{ type: "text", text }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: {
      input_tokens: 0,
      output_tokens: Math.max(1, Math.ceil(text.length / 4)),
    },
  };
}

function writeAnthropicMessage(res, body, text) {
  const message = createAnthropicMessage(body?.model, text);

  if (body?.stream === true) {
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    res.write(`event: message_start\ndata: ${JSON.stringify({ type: "message_start", message: { ...message, content: [], stop_reason: null } })}\n\n`);
    res.write(`event: content_block_start\ndata: ${JSON.stringify({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } })}\n\n`);
    res.write(`event: content_block_delta\ndata: ${JSON.stringify({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text } })}\n\n`);
    res.write(`event: content_block_stop\ndata: ${JSON.stringify({ type: "content_block_stop", index: 0 })}\n\n`);
    res.write(`event: message_delta\ndata: ${JSON.stringify({ type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: message.usage })}\n\n`);
    res.write(`event: message_stop\ndata: ${JSON.stringify({ type: "message_stop" })}\n\n`);
    res.end();
    return;
  }

  res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(message));
}

function extractTextFromAnthropicMessage(message) {
  if (!message || typeof message !== "object" || !Array.isArray(message.content)) {
    return "";
  }
  return message.content
    .map((block) => (block?.type === "text" && typeof block.text === "string" ? block.text : ""))
    .join("");
}

function extractJsonObjectText(text) {
  const value = String(text || "").trim();
  const fenced = value.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced) {
    return extractJsonObjectText(fenced[1]);
  }

  const start = value.indexOf("{");
  const end = value.lastIndexOf("}");
  if (start !== -1 && end > start) {
    return value.slice(start, end + 1);
  }

  return value;
}

function normalizeEvaluatorPayload(text) {
  const raw = String(text || "").trim();
  const jsonText = extractJsonObjectText(raw);
  try {
    const parsed = JSON.parse(jsonText);
    if (typeof parsed?.ok === "boolean") {
      return {
        ok: parsed.ok,
        reason: typeof parsed.reason === "string" && parsed.reason.trim() ? parsed.reason.trim() : (parsed.ok ? "The condition is satisfied." : "The condition is not satisfied."),
      };
    }
  } catch {}

  if (/^\s*true\s*$/i.test(raw)) {
    return { ok: true, reason: "The evaluator returned true." };
  }
  if (/^\s*false\s*$/i.test(raw)) {
    return { ok: false, reason: "The evaluator returned false." };
  }

  return {
    ok: false,
    reason: `Evaluator did not return valid JSON: ${raw.slice(0, 300) || "(empty response)"}`,
  };
}

function normalizeEvaluatorMessageBody(rawBody) {
  const parsed = JSON.parse(rawBody.toString("utf8"));
  const text = extractTextFromAnthropicMessage(parsed);
  const normalized = normalizeEvaluatorPayload(text);
  return Buffer.from(JSON.stringify({ ...parsed, content: [{ type: "text", text: JSON.stringify(normalized) }] }), "utf8");
}

function proxyResponse(upstreamRes, res, responseBody, normalizeEvaluatorResponse) {
  if (!normalizeEvaluatorResponse || !String(upstreamRes.headers["content-type"] || "").includes("application/json")) {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    res.end(responseBody);
    return;
  }

  try {
    const normalizedBody = normalizeEvaluatorMessageBody(responseBody);
    res.writeHead(upstreamRes.statusCode || 502, copyHeaders(upstreamRes.headers, normalizedBody.length));
    res.end(normalizedBody);
  } catch {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    res.end(responseBody);
  }
}

function logRequestSummary(body, rewritten) {
  if (process.env.SYSTEM_USER_SHIM_DEBUG_HOOKS !== "1") {
    return;
  }

  const systemText = flattenContentToText(body?.system);
  const messagesText = flattenMessagesToText(body?.messages);
  const rewrittenText = flattenMessagesToText(rewritten?.messages);
  const looksLikeHookPrompt =
    /stopping condition|hook_event_name|last_assistant_message|Answer based on transcript evidence only/i.test(`${systemText}\n${messagesText}`) ||
    /stopping condition|hook_event_name|last_assistant_message|Answer based on transcript evidence only/i.test(rewrittenText);

  if (!looksLikeHookPrompt) {
    return;
  }

  const summary = {
    model: body?.model,
    originalKeys: Object.keys(body || {}),
    rewrittenKeys: Object.keys(rewritten || {}),
    messageCount: Array.isArray(body?.messages) ? body.messages.length : 0,
    originalPreview: `${systemText}\n${messagesText}`.slice(-1200),
    rewrittenPreview: rewrittenText.slice(-1200),
  };
  console.error(`[SHIM] hook prompt summary ${JSON.stringify(summary)}`);
}

function sanitizeToolChoice(toolChoice, tools) {
  if (!toolChoice || typeof toolChoice !== "object") {
    return undefined;
  }
  if (!Array.isArray(tools) || tools.length === 0) {
    return undefined;
  }

  if (toolChoice.type === "tool") {
    const name = typeof toolChoice.name === "string" ? toolChoice.name.trim() : "";
    if (!name || !tools.some((tool) => tool.name === name)) {
      return undefined;
    }
    return { type: "tool", name };
  }

  if (toolChoice.type === "auto" || toolChoice.type === "any") {
    return { type: toolChoice.type };
  }

  return undefined;
}

function sanitizeRequestBody(body) {
  if (!body || typeof body !== "object") {
    return body;
  }

  const sanitized = { ...body };
  for (const key of unsupportedTopLevelKeys) {
    delete sanitized[key];
  }

  if (Array.isArray(body.messages)) {
    sanitized.messages = body.messages.map((message) => sanitizeMessage(message));
  }
  if (body.system !== undefined) {
    sanitized.system = sanitizeContent(body.system);
  }
  if (Array.isArray(body.tools)) {
    sanitized.tools = body.tools.map((tool) => sanitizeTool(tool)).filter((tool) => tool !== null);
  }
  if (!Array.isArray(sanitized.tools) || sanitized.tools.length === 0) {
    delete sanitized.tools;
  }

  sanitized.tool_choice = sanitizeToolChoice(body.tool_choice, sanitized.tools);
  if (sanitized.tool_choice === undefined) {
    delete sanitized.tool_choice;
  }

  if (isStopHookEvaluatorRequest(sanitized)) {
    return compactStopHookEvaluatorRequest(sanitized);
  }

  return sanitized;
}

function convertSystemToUser(body) {
  const model = String(body?.model || "");
  if (!modelPattern.test(model) || !body?.system || shouldPreserveSystem(body)) {
    return body;
  }

  const userContent = normalizeContent(body.system);
  const messages = Array.isArray(body.messages) ? body.messages : [];

  return {
    ...body,
    system: undefined,
    messages: [
      {
        role: "user",
        content: userContent,
      },
      ...messages,
    ],
  };
}

function readRequest(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function copyHeaders(headers, bodyLength) {
  const result = { ...headers };
  delete result.host;
  delete result["content-length"];
  delete result.connection;
  delete result["accept-encoding"];
  delete result["transfer-encoding"];
  if (bodyLength !== undefined) {
    result["content-length"] = String(bodyLength);
  }
  return result;
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.url === "/__health") {
      res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
      res.end("ok");
      return;
    }

    const rawBody = await readRequest(req);
    let bodyBuffer = rawBody;
    let normalizeEvaluatorResponse = false;
    let routeAsMessagesRequest = false;

    if (req.method !== "GET" && rawBody.length > 0) {
      const contentType = String(req.headers["content-type"] || "");
      if (contentType.includes("application/json")) {
        const parsed = JSON.parse(rawBody.toString("utf8"));
        const isStopHookEvaluator = isStopHookEvaluatorRequest(parsed);
        const sanitized = sanitizeRequestBody(parsed);
        const rewritten = convertSystemToUser(sanitized);
        logRequestSummary(parsed, rewritten);
        normalizeEvaluatorResponse = isStopHookEvaluator;
        routeAsMessagesRequest = isStopHookEvaluator;
        bodyBuffer = Buffer.from(JSON.stringify(rewritten), "utf8");
      }
    }

    const targetBase = targetBaseUrl.endsWith("/") ? targetBaseUrl : `${targetBaseUrl}/`;
    const requestPath = routeAsMessagesRequest ? "/v1/messages" : String(req.url || "/");
    const targetPath = requestPath.replace(/^\/+/, "");
    const targetUrl = new URL(targetPath, targetBase);

    const client = targetUrl.protocol === "https:" ? https : http;
    const upstreamReq = client.request(
      targetUrl,
      {
        method: req.method,
        headers: copyHeaders(req.headers, bodyBuffer.length),
      },
      (upstreamRes) => {
        if (!normalizeEvaluatorResponse) {
          res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
          upstreamRes.pipe(res);
          return;
        }

        const chunks = [];
        upstreamRes.on("data", (chunk) => chunks.push(chunk));
        upstreamRes.on("end", () => proxyResponse(upstreamRes, res, Buffer.concat(chunks), normalizeEvaluatorResponse));
      },
    );

    upstreamReq.on("error", (error) => {
      const message = error instanceof Error ? error.message : String(error);
      if (!res.headersSent) {
        res.writeHead(502, { "content-type": "application/json; charset=utf-8" });
      }
      res.end(JSON.stringify({ error: "system-user-shim upstream failed", message }));
    });

    if (req.method !== "GET" && req.method !== "HEAD") {
      upstreamReq.write(bodyBuffer);
    }
    upstreamReq.end();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    res.writeHead(502, { "content-type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ error: "system-user-shim failed", message }));
  }
});

server.listen(port, "127.0.0.1", () => {
  console.error(`system-user-shim listening on http://127.0.0.1:${port}`);
  console.error(`forwarding to ${targetBaseUrl}`);
});
