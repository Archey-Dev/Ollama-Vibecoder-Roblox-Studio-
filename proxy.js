/**

- Ollama Proxy Server for Roblox Studio Plugin
- -----
- Roblox Studio cannot make HTTP requests to localhost directly,
- but it CAN reach 127.0.0.1 on specific ports via HttpService.
- This proxy sits between Studio and Ollama.
- 
- Usage:
- node proxy.js
- node proxy.js –port 3000 –ollama http://localhost:11434
- 
- Requirements:
- Node.js 18+ (uses built-in http module only — no npm install needed)
  */

const http = require(“http”);
const https = require(“https”);
const { URL } = require(“url”);

// ── Config (override via CLI args) ──────────────────────────
const args = process.argv.slice(2);
const getArg = (flag, def) => {
const i = args.indexOf(flag);
return i !== -1 && args[i + 1] ? args[i + 1] : def;
};

const PORT = parseInt(getArg(”–port”, “3000”), 10);
const OLLAMA_BASE = getArg(”–ollama”, “http://localhost:11434”);

console.log(`[Proxy] Starting on port ${PORT}`);
console.log(`[Proxy] Forwarding to Ollama at ${OLLAMA_BASE}`);

// ── Helpers ──────────────────────────────────────────────────
function readBody(req) {
return new Promise((resolve, reject) => {
const chunks = [];
req.on(“data”, (c) => chunks.push(c));
req.on(“end”, () => resolve(Buffer.concat(chunks).toString(“utf8”)));
req.on(“error”, reject);
});
}

function jsonResponse(res, statusCode, obj) {
const body = JSON.stringify(obj);
res.writeHead(statusCode, {
“Content-Type”: “application/json”,
“Access-Control-Allow-Origin”: “*”,
“Content-Length”: Buffer.byteLength(body),
});
res.end(body);
}

function forwardToOllama(path, method, bodyStr) {
return new Promise((resolve, reject) => {
const target = new URL(OLLAMA_BASE + path);
const lib = target.protocol === “https:” ? https : http;

```
const options = {
  hostname: target.hostname,
  port: target.port || (target.protocol === "https:" ? 443 : 80),
  path: target.pathname + target.search,
  method,
  headers: {
    "Content-Type": "application/json",
  },
};

if (bodyStr) {
  options.headers["Content-Length"] = Buffer.byteLength(bodyStr);
}

const req = lib.request(options, (proxyRes) => {
  const chunks = [];
  proxyRes.on("data", (c) => chunks.push(c));
  proxyRes.on("end", () => {
    const text = Buffer.concat(chunks).toString("utf8");
    resolve({ statusCode: proxyRes.statusCode, body: text });
  });
});

req.on("error", reject);

if (bodyStr) {
  req.write(bodyStr);
}
req.end();
```

});
}

// ── Main server ──────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
// CORS preflight
if (req.method === “OPTIONS”) {
res.writeHead(204, {
“Access-Control-Allow-Origin”: “*”,
“Access-Control-Allow-Methods”: “GET, POST, OPTIONS”,
“Access-Control-Allow-Headers”: “Content-Type”,
});
res.end();
return;
}

const url = req.url || “/”;
console.log(`[Proxy] ${req.method} ${url}`);

// ── GET /health ─────────────────────────────────────────────
if (url === “/health” && req.method === “GET”) {
// Check if Ollama is reachable
try {
const result = await forwardToOllama(”/api/tags”, “GET”, null);
if (result.statusCode === 200) {
let models = [];
try {
const data = JSON.parse(result.body);
models = (data.models || []).map((m) => m.name);
} catch (_) {}
jsonResponse(res, 200, {
status: “ok”,
proxy: “running”,
ollama: “connected”,
models,
});
} else {
jsonResponse(res, 200, {
status: “partial”,
proxy: “running”,
ollama: “error”,
ollamaStatus: result.statusCode,
});
}
} catch (err) {
jsonResponse(res, 200, {
status: “partial”,
proxy: “running”,
ollama: “unreachable”,
error: err.message,
});
}
return;
}

// ── GET /models ─────────────────────────────────────────────
if (url === “/models” && req.method === “GET”) {
try {
const result = await forwardToOllama(”/api/tags”, “GET”, null);
const data = JSON.parse(result.body);
const models = (data.models || []).map((m) => m.name);
jsonResponse(res, 200, { models });
} catch (err) {
jsonResponse(res, 500, { error: err.message });
}
return;
}

// ── POST /chat ──────────────────────────────────────────────
// Expected body from plugin:
// { model, system, messages: [{role, content}…], stream: false }
if (url === “/chat” && req.method === “POST”) {
let body;
try {
body = await readBody(req);
} catch (err) {
jsonResponse(res, 400, { error: “Failed to read request body” });
return;
}

```
let payload;
try {
  payload = JSON.parse(body);
} catch (err) {
  jsonResponse(res, 400, { error: "Invalid JSON body" });
  return;
}

// Build Ollama /api/chat request
const ollamaPayload = {
  model: payload.model || "codellama:7b",
  stream: false,
  messages: [],
};

// Add system message if provided
if (payload.system) {
  ollamaPayload.messages.push({ role: "system", content: payload.system });
}

// Add conversation history + current message
if (Array.isArray(payload.messages)) {
  for (const msg of payload.messages) {
    ollamaPayload.messages.push({ role: msg.role, content: msg.content });
  }
}

const ollamaBody = JSON.stringify(ollamaPayload);
console.log(
  `[Proxy] → Ollama model=${ollamaPayload.model} messages=${ollamaPayload.messages.length}`
);

let result;
try {
  result = await forwardToOllama("/api/chat", "POST", ollamaBody);
} catch (err) {
  console.error("[Proxy] Ollama unreachable:", err.message);
  jsonResponse(res, 502, {
    error: "Cannot reach Ollama. Is it running? Try: ollama serve",
    detail: err.message,
  });
  return;
}

if (result.statusCode !== 200) {
  console.error("[Proxy] Ollama returned", result.statusCode, result.body);
  jsonResponse(res, result.statusCode, {
    error: "Ollama error",
    detail: result.body,
  });
  return;
}

// Parse and relay Ollama's response
let ollamaData;
try {
  ollamaData = JSON.parse(result.body);
} catch (err) {
  jsonResponse(res, 500, { error: "Failed to parse Ollama response" });
  return;
}

console.log("[Proxy] ✓ Response received");

// Return in a simple format the plugin understands
jsonResponse(res, 200, {
  message: ollamaData.message || { role: "assistant", content: result.body },
  model: ollamaData.model,
  done: ollamaData.done,
});
return;
```

}

// ── POST /generate (legacy/simple endpoint) ─────────────────
if (url === “/generate” && req.method === “POST”) {
let body;
try {
body = await readBody(req);
} catch (err) {
jsonResponse(res, 400, { error: “Failed to read request body” });
return;
}

```
let payload;
try {
  payload = JSON.parse(body);
} catch (err) {
  jsonResponse(res, 400, { error: "Invalid JSON body" });
  return;
}

const ollamaPayload = {
  model: payload.model || "codellama:7b",
  prompt: payload.prompt || "",
  stream: false,
};

const ollamaBody = JSON.stringify(ollamaPayload);

let result;
try {
  result = await forwardToOllama("/api/generate", "POST", ollamaBody);
} catch (err) {
  jsonResponse(res, 502, {
    error: "Cannot reach Ollama",
    detail: err.message,
  });
  return;
}

let ollamaData;
try {
  ollamaData = JSON.parse(result.body);
} catch (err) {
  jsonResponse(res, 500, { error: "Failed to parse Ollama response" });
  return;
}

jsonResponse(res, 200, {
  content: ollamaData.response,
  message: { role: "assistant", content: ollamaData.response },
  done: ollamaData.done,
});
return;
```

}

// ── 404 fallback ─────────────────────────────────────────────
jsonResponse(res, 404, { error: “Unknown endpoint: “ + url });
});

server.listen(PORT, “127.0.0.1”, () => {
console.log(”\n╔══════════════════════════════════════════╗”);
console.log(`║  Ollama Proxy running on port ${PORT}       ║`);
console.log(“╠══════════════════════════════════════════╣”);
console.log(`║  Ollama endpoint: ${OLLAMA_BASE.padEnd(22)}║`);
console.log(“║                                          ║”);
console.log(“║  Endpoints:                              ║”);
console.log(“║    GET  /health   → check status        ║”);
console.log(“║    GET  /models   → list models         ║”);
console.log(“║    POST /chat     → chat with Ollama    ║”);
console.log(“╚══════════════════════════════════════════╝”);
console.log(”\nLeave this running while using the plugin.”);
console.log(“Press Ctrl+C to stop.\n”);
});

server.on(“error”, (err) => {
if (err.code === “EADDRINUSE”) {
console.error(`\n✗ Port ${PORT} is already in use.`);
console.error(
`  Either another proxy is running (that's fine!), or use --port to pick another.\n`
);
} else {
console.error(“Server error:”, err);
}
});
