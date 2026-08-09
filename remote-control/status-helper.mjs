#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const timeoutMs = Number.parseInt(process.argv[2] || "5000", 10);
const child = spawn("codex", ["app-server", "proxy"], {
  env: { ...process.env, CODEX_HOME: "/home/coder/.codex" },
  stdio: ["pipe", "pipe", "pipe"],
});
let stderr = "";
let finished = false;
let timer;

function finish(value, code = 0) {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  process.stdout.write(`${JSON.stringify(value)}\n`);
  child.kill("SIGTERM");
  setTimeout(() => child.kill("SIGKILL"), 500).unref();
  process.exitCode = code;
}

child.stderr.on("data", chunk => { stderr += chunk.toString(); });
child.on("error", error => finish({ remote_status: "unknown", error: error.message }, 1));
child.on("exit", code => {
  if (!finished) finish({ remote_status: "unknown", error: stderr.trim() || `proxy exited with status ${code}` }, 1);
});

const lines = createInterface({ input: child.stdout });
lines.on("line", line => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.id === 1) {
    if (message.error) {
      finish({ remote_status: "unknown", error: message.error.message || "App Server initialization failed" }, 1);
      return;
    }
    child.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);
    return;
  }
  if (message.method !== "remoteControl/status/changed") return;
  const params = message.params || {};
  finish({
    remote_status: params.status || "unknown",
    installation_id: params.installationId || null,
    server_name: params.serverName || null,
    environment_id: params.environmentId || null,
  });
});

child.stdin.write(`${JSON.stringify({
  id: 1,
  method: "initialize",
  params: {
    clientInfo: { name: "agentctl", title: "agentctl", version: "1" },
    capabilities: { experimentalApi: true },
  },
})}\n`);

timer = setTimeout(() => finish({ remote_status: "unknown", error: "timed out waiting for remote-control status" }), timeoutMs);
