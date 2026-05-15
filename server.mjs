#!/usr/bin/env node
import http from "node:http";
import https from "node:https";
import { URL } from "node:url";

const port = Number(process.env.SYSTEM_USER_SHIM_PORT || 17861);
const targetBaseUrl = process.env.SYSTEM_USER_SHIM_TARGET_BASE_URL;
const modelPattern = new RegExp(process.env.SYSTEM_USER_SHIM_MODEL_PATTERN || "minimax", "i");

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

function convertSystemToUser(body) {
  const model = String(body?.model || "");
  if (!modelPattern.test(model) || !body?.system) {
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

    const targetBase = targetBaseUrl.endsWith("/") ? targetBaseUrl : `${targetBaseUrl}/`;
    const targetPath = String(req.url || "/").replace(/^\/+/, "");
    const targetUrl = new URL(targetPath, targetBase);
    const rawBody = await readRequest(req);
    let bodyBuffer = rawBody;

    if (req.method !== "GET" && rawBody.length > 0) {
      const contentType = String(req.headers["content-type"] || "");
      if (contentType.includes("application/json")) {
        const parsed = JSON.parse(rawBody.toString("utf8"));
        const rewritten = convertSystemToUser(parsed);
        bodyBuffer = Buffer.from(JSON.stringify(rewritten), "utf8");
      }
    }

    const client = targetUrl.protocol === "https:" ? https : http;
    const upstreamReq = client.request(
      targetUrl,
      {
        method: req.method,
        headers: copyHeaders(req.headers, bodyBuffer.length),
      },
      (upstreamRes) => {
        res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
        upstreamRes.pipe(res);
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
