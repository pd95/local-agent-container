#!/usr/bin/env node
import { spawn } from "node:child_process";
import http from "node:http";
import { randomUUID } from "node:crypto";

const command = process.argv[2];
const args = process.argv.slice(3);
if (!command) {
  console.error("Usage: mcp-stdio-http-relay.mjs <command> [args...]");
  process.exit(2);
}

const host = process.env.MCP_RELAY_HOST || "0.0.0.0";
const advertisedHost = process.env.MCP_RELAY_ADVERTISE_HOST;
if (!advertisedHost) {
  console.error("MCP_RELAY_ADVERTISE_HOST must be set to a host address reachable from the container");
  process.exit(2);
}
const requestedPort = Number(process.env.MCP_RELAY_PORT || 0);
const logPrefix = process.env.MCP_RELAY_NAME || command;
const sessions = new Map();
let defaultSession = null;
let cachedInitializeResponse = null;

const log = (message, details = {}) => {
  console.error(JSON.stringify({ ts: new Date().toISOString(), relay: logPrefix, message, ...details }));
};

const writeSse = (res, event) => {
  res.write(`event: message\n`);
  res.write(`data: ${JSON.stringify(event)}\n\n`);
};

const createSession = () => {
  const id = randomUUID();
  const child = spawn(command, args, {
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const session = {
    id,
    child,
    responses: [],
    responseWaiters: new Map(),
    waiters: [],
    buffer: "",
    closed: false,
    initializedNotified: false,
  };
  sessions.set(id, session);

  child.stdout.on("data", (chunk) => {
    session.buffer += chunk.toString("utf8");
    const lines = session.buffer.split("\n");
    session.buffer = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        log("non-json-stdio-stdout", { sessionId: id, line: line.slice(0, 500) });
        continue;
      }
      if (message.id !== undefined && session.responseWaiters.has(message.id)) {
        const waiter = session.responseWaiters.get(message.id);
        session.responseWaiters.delete(message.id);
        waiter(message);
        continue;
      }
      const waiter = session.waiters.shift();
      if (waiter) {
        writeSse(waiter.res, message);
        waiter.res.end();
      } else {
        session.responses.push(message);
      }
    }
  });

  child.stderr.on("data", (chunk) => {
    log("stdio-stderr", { sessionId: id, text: chunk.toString("utf8") });
  });

  child.on("exit", (code, signal) => {
    session.closed = true;
    log("stdio-exit", { sessionId: id, code, signal });
    for (const waiter of session.waiters.splice(0)) {
      waiter.res.statusCode = 502;
      waiter.res.end();
    }
    sessions.delete(id);
  });

  child.on("error", (error) => {
    session.closed = true;
    log("stdio-error", { sessionId: id, error: error.message });
  });

  log("session-created", { sessionId: id, command, args });
  return session;
};

const waitForResponse = (session, id, timeoutMs = 30000) => new Promise((resolve, reject) => {
  const timeout = setTimeout(() => {
    session.responseWaiters.delete(id);
    reject(new Error(`Timed out waiting for JSON-RPC response id=${id}`));
  }, timeoutMs);
  session.responseWaiters.set(id, (message) => {
    clearTimeout(timeout);
    resolve(message);
  });
});

const writeJsonResponse = (res, session, message) => {
  res.statusCode = 200;
  res.setHeader("content-type", "application/json");
  res.setHeader("mcp-session-id", session.id);
  res.end(JSON.stringify(message));
};

const withResponseId = (message, id) => ({ ...message, id });

const toolNamesFromResponse = (response) => {
  const tools = response?.result?.tools;
  if (!Array.isArray(tools)) return null;
  return tools.map((tool) => tool?.name).filter(Boolean).sort();
};

const handlePostBody = async (body, message, res, session) => {
  if (message.method === "notifications/initialized" && session.initializedNotified) {
    res.statusCode = 202;
    res.setHeader("mcp-session-id", session.id);
    res.end();
    return;
  }
  if (message.method === "notifications/initialized") {
    session.initializedNotified = true;
  }
  if (message.id === undefined || message.id === null) {
    session.child.stdin.write(`${body}\n`);
    res.statusCode = 202;
    res.setHeader("mcp-session-id", session.id);
    res.end();
    return;
  }

  try {
    const responsePromise = waitForResponse(session, message.id);
    if (message.method === "tools/list") {
      log("tools-list-request", { sessionId: session.id, id: message.id });
    }
    session.child.stdin.write(`${body}\n`);
    const response = await responsePromise;
    if (message.method === "initialize") {
      cachedInitializeResponse = response;
    }
    if (message.method === "tools/list") {
      const toolNames = toolNamesFromResponse(response);
      log("tools-list-response", {
        sessionId: session.id,
        id: message.id,
        count: toolNames?.length ?? null,
        tools: toolNames,
      });
    }
    writeJsonResponse(res, session, response);
  } catch (error) {
    log("response-timeout", { sessionId: session.id, id: message.id, error: error.message });
    res.statusCode = 504;
    res.setHeader("mcp-session-id", session.id);
    res.end(error.message);
  }
};

const readBody = async (req) => {
  let body = "";
  for await (const chunk of req) body += chunk.toString("utf8");
  return body;
};

const parseJsonRpc = (body) => {
  try {
    return JSON.parse(body);
  } catch {
    return null;
  }
};

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/health") {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (req.method === "POST" && req.url === "/mcp") {
      const sessionId = req.headers["mcp-session-id"];
      const existingSession = sessions.get(Array.isArray(sessionId) ? sessionId[0] : sessionId);
      const body = await readBody(req);
      const message = parseJsonRpc(body);
      if (!message) {
        res.statusCode = 400;
        res.end("Invalid JSON-RPC body");
        return;
      }

      if (!existingSession && defaultSession && message.method === "initialize" && cachedInitializeResponse) {
        writeJsonResponse(res, defaultSession, withResponseId(cachedInitializeResponse, message.id));
        return;
      }

      const session = existingSession || defaultSession || createSession();
      if (!defaultSession) {
        defaultSession = session;
      }
      await handlePostBody(body, message, res, session);
      return;
    }

    if (req.method === "POST" && req.url === "/mcp/message") {
      const sessionId = req.headers["mcp-session-id"];
      const session = sessions.get(Array.isArray(sessionId) ? sessionId[0] : sessionId);
      if (!session || session.closed) {
        res.statusCode = 404;
        res.end("Unknown MCP session");
        return;
      }
      const body = await readBody(req);
      const message = parseJsonRpc(body);
      if (!message) {
        res.statusCode = 400;
        res.end("Invalid JSON-RPC body");
        return;
      }
      await handlePostBody(body, message, res, session);
      return;
    }

    if (req.method === "GET" && req.url === "/mcp") {
      const sessionId = req.headers["mcp-session-id"];
      const session = sessions.get(Array.isArray(sessionId) ? sessionId[0] : sessionId);
      if (!session || session.closed) {
        res.statusCode = 404;
        res.end("Unknown MCP session");
        return;
      }
      res.statusCode = 200;
      res.setHeader("content-type", "text/event-stream");
      res.setHeader("cache-control", "no-cache");
      res.setHeader("connection", "keep-alive");
      if (session.responses.length > 0) {
        for (const message of session.responses.splice(0)) {
          writeSse(res, message);
        }
        res.end();
      } else {
        session.waiters.push({ res });
      }
      return;
    }

    res.statusCode = 404;
    res.end("Not found");
  } catch (error) {
    log("request-error", { error: error.message });
    res.statusCode = 500;
    res.end(error.message);
  }
});

server.listen(requestedPort, host, () => {
  const address = server.address();
  console.log(JSON.stringify({ url: `http://${advertisedHost}:${address.port}/mcp`, listenHost: host }));
});
