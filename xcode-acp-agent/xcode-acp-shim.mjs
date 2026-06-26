#!/usr/bin/env node
import { spawn } from "node:child_process";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, createWriteStream, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { basename, dirname } from "node:path";

const home = process.env.HOME || "/tmp";
const processCwd = process.cwd();
const codingAssistantDirFromCwd = (() => {
  const match = processCwd.match(/^(.*\/Library\/Developer\/Xcode\/CodingAssistant\/[0-9A-Fa-f-]+)(?:\/.*)?$/);
  return match ? match[1] : null;
})();
const codingAssistantDir = process.env.AGENTCTL_XCODE_ASSISTANT_DIR || codingAssistantDirFromCwd;
const useXcodeHome = process.env.AGENTCTL_XCODE_USE_ASSISTANT_HOME !== "0" && Boolean(codingAssistantDir);
const agentRuntime = (process.env.AGENTCTL_XCODE_AGENT || process.env.AGENTCTL_XCODE_RUNTIME || "codex").toLowerCase();
if (!["codex", "claude"].includes(agentRuntime)) {
  throw new Error(`Unsupported AGENTCTL_XCODE_AGENT/AGENTCTL_XCODE_RUNTIME: ${agentRuntime}`);
}
const runtimeDisplayName = agentRuntime === "claude" ? "Claude" : "Codex";
const runtimeHomeSubdir = agentRuntime === "claude" ? ".claude" : ".codex";
const runtimeSkillsSubdir = agentRuntime === "claude" ? ".claude/skills" : ".codex/skills";
const defaultAcpPackage = agentRuntime === "claude"
  ? "@agentclientprotocol/claude-agent-acp"
  : "@agentclientprotocol/codex-acp";
const acpPackage = process.env.AGENTCTL_XCODE_ACP_PACKAGE || defaultAcpPackage;
const acpCommand = process.env.AGENTCTL_XCODE_ACP_COMMAND || `npx -y ${acpPackage}`;
const runtimeOnline = process.env.AGENTCTL_XCODE_RUNTIME_ONLINE !== "0";
const installRuntime = process.env.AGENTCTL_XCODE_INSTALL_RUNTIME === "1";
const xcodeHomeDir = process.env.AGENTCTL_XCODE_HOME_DIR ||
  (useXcodeHome ? `${codingAssistantDir}/home` : null);
const xcodeLogDir = process.env.AGENTCTL_XCODE_LOG_DIR ||
  (useXcodeHome ? `${codingAssistantDir}/logs` : `${home}/Library/Logs/agentctl`);
const logFile = process.env.AGENTCTL_XCODE_ACP_SHIM_LOG ||
  `${xcodeLogDir}/xcode-${agentRuntime}-acp-shim.log`;
mkdirSync(dirname(logFile), { recursive: true });
const log = createWriteStream(logFile, { flags: "a" });
const sessionStoreFile = process.env.AGENTCTL_XCODE_ACP_SESSION_STORE ||
  `${xcodeLogDir}/xcode-${agentRuntime}-acp-sessions.json`;
const xcodeSkillsDir = process.env.AGENTCTL_XCODE_SKILLS_DIR ||
  (xcodeHomeDir ? `${xcodeHomeDir}/${runtimeSkillsSubdir}` : null);
const exportXcodeSkills = process.env.AGENTCTL_XCODE_EXPORT_SKILLS !== "0" && Boolean(xcodeSkillsDir);
const hostGlobalSkillsDir = process.env.AGENTCTL_HOST_SKILLS_DIR || `${home}/.agents/skills`;
const assistantSkillsDir = codingAssistantDir ? `${codingAssistantDir}/skills` : null;

const repoRoot = dirname(dirname(new URL(import.meta.url).pathname));
const agentctl = process.env.AGENTCTL || `${repoRoot}/agentctl`;
const containerCmd = process.env.CONTAINER_CMD || "container";
const image = process.env.AGENTCTL_XCODE_IMAGE || "agent-plain";
const containerPrefix = process.env.AGENTCTL_XCODE_CONTAINER_PREFIX || "agent-xcode-";
const containerNameSalt = process.env.AGENTCTL_XCODE_CONTAINER_SALT || `assistant-home-v2-${agentRuntime}`;
const bridgeMcp = process.env.AGENTCTL_XCODE_BRIDGE_MCP !== "0";
const stripMcp = process.env.AGENTCTL_XCODE_STRIP_MCP !== "0" && !bridgeMcp;
const startupTimeoutMs = Number(process.env.AGENTCTL_XCODE_STARTUP_TIMEOUT_MS || 120000);
const defaultAuthRequest = process.env.DEFAULT_AUTH_REQUEST || JSON.stringify({ methodId: "chat-gpt" });
const resumeFallbackLastProject = process.env.AGENTCTL_XCODE_RESUME_FALLBACK_LAST_PROJECT !== "0";
const resetConfigForAssistantHome = process.env.AGENTCTL_XCODE_RESET_CONFIG !== "0" && agentRuntime === "codex";
const relayScript = `${dirname(new URL(import.meta.url).pathname)}/mcp-stdio-http-relay.mjs`;
const mcpRelays = [];

let agent = null;
let agentReady = false;
let pendingClientLines = [];
let clientBuffer = "";
let agentBuffer = "";
let sawSessionNew = false;
let startupTimer = null;
let clientInitializeParams = null;
let initializingAgent = false;
let agentInitialized = false;
const internalInitializeId = "agentctl-internal-initialize";
let pendingSessionNewLine = null;
const pendingSessionContexts = new Map();
let retriedStartWithoutHome = false;

const timestamp = () => new Date().toISOString();

const writeLog = (event, details = {}) => {
  log.write(`${JSON.stringify({ ts: timestamp(), event, ...details })}\n`);
};

const ensureDirectory = (path) => {
  if (!path) return;
  mkdirSync(path, { recursive: true });
};

const ensureSymlink = (linkPath, target) => {
  try {
    if (existsSync(linkPath)) return;
    ensureDirectory(dirname(linkPath));
    symlinkSync(target, linkPath);
    writeLog("symlink-created", { linkPath, target });
  } catch (error) {
    writeLog("symlink-error", { linkPath, target, error: error.message });
  }
};

const replaceSymlink = (linkPath, target) => {
  try {
    if (existsSync(linkPath)) {
      rmSync(linkPath, { force: true, recursive: false });
    }
    ensureDirectory(dirname(linkPath));
    symlinkSync(target, linkPath);
    writeLog("symlink-created", { linkPath, target });
  } catch (error) {
    writeLog("symlink-error", { linkPath, target, error: error.message });
  }
};

const syncHostGlobalSkills = () => {
  if (!xcodeSkillsDir || !existsSync(hostGlobalSkillsDir)) return;
  if (assistantSkillsDir) {
    replaceSymlink(`${assistantSkillsDir}/global`, hostGlobalSkillsDir);
  }

  const linked = [];
  for (const entry of readdirSync(hostGlobalSkillsDir, { withFileTypes: true })) {
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
    const source = `${hostGlobalSkillsDir}/${entry.name}`;
    const target = `${xcodeSkillsDir}/${entry.name}`;
    if (existsSync(target)) {
      linked.push({ name: entry.name, status: "skipped-existing" });
      continue;
    }
    try {
      cpSync(source, target, {
        recursive: true,
        dereference: true,
        errorOnExist: false,
        force: false,
      });
      linked.push({ name: entry.name, status: "copied" });
    } catch (error) {
      linked.push({ name: entry.name, status: "error", error: error.message });
    }
  }
  writeLog("host-global-skills-sync", { hostGlobalSkillsDir, xcodeSkillsDir, linked });
};

const ensureXcodeHomeTree = () => {
  if (!xcodeHomeDir) return null;
  ensureDirectory(`${xcodeHomeDir}/${runtimeHomeSubdir}`);
  ensureDirectory(`${xcodeHomeDir}/.agents`);
  if (assistantSkillsDir) ensureDirectory(assistantSkillsDir);
  if (xcodeSkillsDir) ensureDirectory(xcodeSkillsDir);
  ensureSymlink(`${xcodeHomeDir}/.agents/skills`, `../${runtimeSkillsSubdir}`);
  return xcodeHomeDir;
};

const mcpEnvFromServers = (servers) => {
  const env = {};
  if (!Array.isArray(servers)) return env;
  for (const server of servers) {
    if (!Array.isArray(server.env)) continue;
    for (const item of server.env) {
      if (item?.name) env[item.name] = item.value ?? "";
    }
  }
  return env;
};

const exportSkillsIfNeeded = (servers) => {
  if (!exportXcodeSkills || !xcodeSkillsDir) return;
  ensureXcodeHomeTree();
  const marker = `${xcodeSkillsDir}/.agentctl-exported`;
  const replaceExisting = process.env.AGENTCTL_XCODE_EXPORT_SKILLS_REPLACE === "1" || !existsSync(marker);
  const args = [
    "mcpbridge",
    "run-agent",
    "skills",
    "export",
    "--output-dir",
    xcodeSkillsDir,
  ];
  if (replaceExisting) {
    args.push("--replace-existing");
  }
  const result = spawnSync("xcrun", args, {
    env: {
      ...process.env,
      ...mcpEnvFromServers(servers),
    },
    encoding: "utf8",
  });
  writeLog("xcode-skills-export", {
    xcodeSkillsDir,
    replaceExisting,
    status: result.status,
    signal: result.signal,
    stdout: result.stdout?.slice(0, 2000),
    stderr: result.stderr?.slice(0, 4000),
  });
  if (result.status === 0) {
    writeFileSync(marker, `${timestamp()}\n`, { mode: 0o600 });
  }
  syncHostGlobalSkills();
};

const readSessionStore = () => {
  try {
    return JSON.parse(readFileSync(sessionStoreFile, "utf8"));
  } catch {
    return {};
  }
};

const writeSessionStore = (store) => {
  try {
    writeFileSync(sessionStoreFile, `${JSON.stringify(store, null, 2)}\n`, { mode: 0o600 });
  } catch (error) {
    writeLog("session-store-write-error", { error: error.message, sessionStoreFile });
  }
};

const saveSessionContext = (sessionId, context) => {
  if (!sessionId || !context?.cwd) return;
  const store = readSessionStore();
  store[sessionId] = {
    cwd: context.cwd,
    containerName: context.containerName,
    image,
    savedAt: timestamp(),
  };
  writeSessionStore(store);
  writeLog("session-context-saved", { sessionId, cwd: context.cwd, containerName: context.containerName });
};

const saveLastProjectContext = (context) => {
  if (!context?.cwd) return;
  const store = readSessionStore();
  store.__lastProjectContext = {
    cwd: context.cwd,
    containerName: context.containerName,
    image,
    savedAt: timestamp(),
  };
  writeSessionStore(store);
  writeLog("last-project-context-saved", { cwd: context.cwd, containerName: context.containerName });
};

const loadSessionContext = (sessionId) => {
  if (!sessionId) return null;
  const context = readSessionStore()[sessionId] || null;
  writeLog("session-context-load", {
    sessionId,
    found: Boolean(context),
    cwd: context?.cwd,
    containerName: context?.containerName,
  });
  return context;
};

const loadResumeFallbackContext = (sessionId) => {
  if (!resumeFallbackLastProject) return null;
  const context = readSessionStore().__lastProjectContext || null;
  writeLog("session-resume-fallback-last-project", {
    sessionId,
    found: Boolean(context),
    cwd: context?.cwd,
    containerName: context?.containerName,
  });
  return context;
};

const redact = (value) => {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === "object") {
    const out = {};
    for (const [key, item] of Object.entries(value)) {
      if (/token|secret|password|key|auth|credential|cookie|session/i.test(key)) {
        out[key] = "<redacted>";
      } else {
        out[key] = redact(item);
      }
    }
    return out;
  }
  return value;
};

const sanitizeContainerPart = (value) => {
  const safe = value.toLowerCase().replace(/[^a-z0-9_.-]+/g, "-").replace(/^-+|-+$/g, "");
  return safe || "project";
};

const shellQuote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;

const shellEnvAssignments = (names) =>
  names
    .filter((name) => Object.prototype.hasOwnProperty.call(process.env, name))
    .map((name) => `${name}=${shellQuote(process.env[name] ?? "")}`)
    .join(" ");

const containerNameForCwd = (cwd) => {
  const name = sanitizeContainerPart(basename(cwd));
  const hashInput = xcodeHomeDir ? `${cwd}\n${xcodeHomeDir}\n${containerNameSalt}` : cwd;
  const hash = createHash("sha256").update(hashInput).digest("hex").slice(0, 10);
  return `${containerPrefix}${name}-${hash}`.slice(0, 63);
};

const ensureContainer = (cwd) => {
  if (!cwd || !cwd.startsWith("/")) {
    throw new Error(`session/new cwd must be an absolute path: ${cwd}`);
  }
  if (!existsSync(cwd)) {
    throw new Error(`session/new cwd does not exist on host: ${cwd}`);
  }

  const containerName = process.env.AGENTCTL_XCODE_CONTAINER_NAME || containerNameForCwd(cwd);
  writeLog("ensure-container", { cwd, image, containerName });

  return containerName;
};

const sessionIdFromParams = (params) =>
  params?.sessionId ||
  params?.session?.sessionId ||
  params?.session?.id ||
  params?.id ||
  null;

const writeJsonRpcError = (id, code, message) => {
  process.stdout.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id,
    error: {
      code,
      message,
    },
  })}\n`);
};

const startMcpRelay = (server) => new Promise((resolve, reject) => {
  const env = { ...process.env };
  if (Array.isArray(server.env)) {
    for (const item of server.env) {
      if (item?.name) env[item.name] = item.value ?? "";
    }
  }
  env.MCP_RELAY_NAME = server.name || server.command;

  const relay = spawn(process.execPath, [relayScript, server.command, ...(server.args || [])], {
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stdout = "";
  const timeout = setTimeout(() => {
    relay.kill("SIGTERM");
    reject(new Error(`Timed out starting MCP relay for ${server.name}`));
  }, 10000);

  relay.stdout.on("data", (chunk) => {
    stdout += chunk.toString("utf8");
    const lines = stdout.split("\n");
    stdout = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const message = JSON.parse(line);
        if (message.url) {
          clearTimeout(timeout);
          mcpRelays.push(relay);
          writeLog("mcp-relay-started", {
            name: server.name,
            command: server.command,
            args: server.args,
            url: message.url,
          });
          resolve({
            name: server.name,
            type: "http",
            url: message.url,
            headers: [],
          });
          return;
        }
      } catch {
        writeLog("mcp-relay-non-json", { name: server.name, line: line.slice(0, 500) });
      }
    }
  });

  relay.stderr.on("data", (chunk) => {
    writeLog("mcp-relay-stderr", { name: server.name, text: chunk.toString("utf8") });
  });

  relay.on("error", (error) => {
    clearTimeout(timeout);
    reject(error);
  });

  relay.on("exit", (code, signal) => {
    writeLog("mcp-relay-exit", { name: server.name, code, signal });
  });
});

const rewriteMcpServers = async (servers) => {
  if (!Array.isArray(servers) || servers.length === 0) return [];
  if (bridgeMcp) {
    const rewritten = [];
    for (const server of servers) {
      if (server.command && Array.isArray(server.args)) {
        rewritten.push(await startMcpRelay(server));
      } else {
        rewritten.push(server);
      }
    }
    writeLog("bridge-mcp-servers", { rewritten });
    return rewritten;
  }
  if (stripMcp) {
    writeLog("strip-mcp-servers", {
      stripped: servers.map((server) => ({
        name: server.name,
        command: server.command,
        args: server.args,
      })),
    });
    return [];
  }
  return servers;
};

const startAgent = (containerName, cwd, includeHomeMount = true) => {
  if (agent) return;
  const assistantHome = includeHomeMount ? ensureXcodeHomeTree() : null;
  let stderrBuffer = "";
  writeLog("start-agent", { containerName, cwd, assistantHome, includeHomeMount });
  const commandEnv = agentRuntime === "codex"
    ? [
      `DEFAULT_AUTH_REQUEST=${shellQuote(defaultAuthRequest)}`,
      `NO_BROWSER=${shellQuote(process.env.NO_BROWSER || "1")}`,
    ].join(" ")
    : shellEnvAssignments([
      "ANTHROPIC_API_KEY",
      "ANTHROPIC_AUTH_TOKEN",
      "ANTHROPIC_BASE_URL",
      "ANTHROPIC_MODEL",
      "CLAUDE_CODE_OAUTH_TOKEN",
    ]);
  const commandEnvPrefix = commandEnv ? `${commandEnv} ` : "";
  const containerCommand = `cd /workdir && ${commandEnvPrefix}${acpCommand}`;
  const args = [
    "run",
    "--stdio",
    "--name",
    containerName,
    "--image",
    image,
    "--workdir",
    cwd,
  ];
  if (assistantHome) {
    args.push("--home", assistantHome);
  }
  args.push(
    "--runtime",
    agentRuntime,
  );
  if (runtimeOnline) {
    args.push("--online");
  }
  if (installRuntime) {
    args.push("--install-runtime");
  }
  if (assistantHome && resetConfigForAssistantHome) {
    args.push("--reset-config");
  }
  args.push(
    "--cmd",
    "sh",
    "-lc",
    containerCommand,
  );
  agent = spawn(agentctl, args, {
    env: {
      ...process.env,
      DEFAULT_AUTH_REQUEST: defaultAuthRequest,
      NO_BROWSER: process.env.NO_BROWSER || "1",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });

  startupTimer = setTimeout(() => {
    writeLog("agent-startup-timeout", { timeoutMs: startupTimeoutMs });
  }, startupTimeoutMs);

  agent.on("error", (error) => {
    writeLog("agent-error", { error: error.message });
    process.exit(1);
  });

  agent.on("exit", (code, signal) => {
    writeLog("agent-exit", { code, signal });
    if (
      code !== 0 &&
      assistantHome &&
      !retriedStartWithoutHome &&
      stderrBuffer.includes("--home only applies when creating a new container")
    ) {
      writeLog("agent-retry-without-home", { containerName, cwd });
      retriedStartWithoutHome = true;
      agent = null;
      initializingAgent = false;
      agentInitialized = false;
      startAgent(containerName, cwd, false);
      initializeAgent();
      return;
    }
    process.exit(code ?? 1);
  });

  agent.stderr.on("data", (chunk) => {
    const text = chunk.toString("utf8");
    stderrBuffer += text;
    if (stderrBuffer.length > 8000) {
      stderrBuffer = stderrBuffer.slice(-8000);
    }
    writeLog("agent-stderr", { text });
    process.stderr.write(chunk);
  });

  agent.stdout.on("data", (chunk) => {
    if (startupTimer) {
      clearTimeout(startupTimer);
      startupTimer = null;
    }
    agentBuffer = splitLines(agentBuffer, chunk, "agent-to-client");
  });
};

const forwardClientLine = (line) => {
  if (agent && agentInitialized) {
    agent.stdin.write(`${line}\n`);
  } else {
    pendingClientLines.push(line);
  }
};

const flushPendingClientLines = () => {
  if (!agent || !agentInitialized) return;
  for (const line of pendingClientLines) {
    agent.stdin.write(`${line}\n`);
  }
  pendingClientLines = [];
};

const initializeAgent = () => {
  if (!agent || initializingAgent || agentInitialized) return;
  initializingAgent = true;
  const initialize = {
    jsonrpc: "2.0",
    id: internalInitializeId,
    method: "initialize",
    params: clientInitializeParams || {
      protocolVersion: 1,
      clientCapabilities: {
        terminal: true,
        fs: {
          readTextFile: true,
          writeTextFile: true,
        },
      },
      clientInfo: {
        name: "agentctl-xcode-acp-shim",
        title: "agentctl Xcode ACP Shim",
        version: "0.1.0",
      },
    },
  };
  writeLog("agent-initialize", { params: redact(initialize.params) });
  agent.stdin.write(`${JSON.stringify(initialize)}\n`);
};

const clientInitializeResponse = (id) => ({
  jsonrpc: "2.0",
  id,
  result: {
    protocolVersion: 1,
    agentInfo: {
      name: `agentctl-xcode-${agentRuntime}-acp-shim`,
      title: `${runtimeDisplayName} Container`,
      version: "0.1.0",
    },
    agentCapabilities: {
      auth: {
        logout: {},
      },
      loadSession: true,
      promptCapabilities: {
        embeddedContext: true,
        image: true,
      },
      sessionCapabilities: {
        resume: {},
        list: {},
        close: {},
        delete: {},
        additionalDirectories: {},
      },
      mcpCapabilities: {
        acp: false,
        http: true,
        sse: false,
      },
    },
    authMethods: [
      {
        id: "api-key",
        name: "API Key",
        description: "Use an API key to authenticate",
        _meta: {
          "api-key": {
            provider: agentRuntime === "claude" ? "anthropic" : "openai",
          },
        },
      },
      ...(agentRuntime === "codex" ? [{
        id: "chat-gpt",
        name: "ChatGPT",
        description: "Use ChatGPT to authenticate",
      }] : []),
    ],
  },
});

const handleClientLine = async (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    writeLog("client-non-json", { line: line.slice(0, 500) });
    forwardClientLine(line);
    return;
  }

  writeLog("client-message", {
    id: message.id,
    method: message.method,
    params: redact(message.params),
  });

  if (message.method === "initialize") {
    clientInitializeParams = message.params;
    process.stdout.write(`${JSON.stringify(clientInitializeResponse(message.id))}\n`);
    return;
  }

  if (message.method === "session/new") {
    sawSessionNew = true;
    const originalCwd = message.params?.cwd;
    try {
      const containerName = ensureContainer(originalCwd);
      exportSkillsIfNeeded(message.params?.mcpServers);
      startAgent(containerName, originalCwd);
      message.params.cwd = "/workdir";
      message.params.mcpServers = await rewriteMcpServers(message.params.mcpServers);
      pendingSessionNewLine = JSON.stringify(message);
      pendingSessionContexts.set(message.id, { cwd: originalCwd, containerName });
      saveLastProjectContext({ cwd: originalCwd, containerName });
      pendingClientLines.push(pendingSessionNewLine);
      initializeAgent();
    } catch (error) {
      writeLog("session-new-error", { error: error.message });
      writeJsonRpcError(message.id, -32000, error.message);
    }
    return;
  }

  if (message.method === "session/resume" && !agent) {
    const sessionId = sessionIdFromParams(message.params);
    const context = loadSessionContext(sessionId) || loadResumeFallbackContext(sessionId);
    if (!context?.cwd) {
      writeLog("session-resume-missing-context", { id: message.id, sessionId, params: redact(message.params) });
      writeJsonRpcError(
        message.id,
        -32000,
        `Cannot resume ACP session ${sessionId || "<unknown>"} because this shim has no saved project context for it. Start a new Xcode conversation once so future resumes can be mapped to a project container.`,
      );
      return;
    }
    try {
      const containerName = xcodeHomeDir ? ensureContainer(context.cwd) : (context.containerName || ensureContainer(context.cwd));
      exportSkillsIfNeeded(message.params?.mcpServers);
      startAgent(containerName, context.cwd);
      if (message.params?.cwd) {
        message.params.cwd = "/workdir";
      }
      if (Array.isArray(message.params?.mcpServers)) {
        message.params.mcpServers = await rewriteMcpServers(message.params.mcpServers);
      }
      pendingClientLines.push(JSON.stringify(message));
      initializeAgent();
    } catch (error) {
      writeLog("session-resume-error", { id: message.id, sessionId, error: error.message });
      writeJsonRpcError(message.id, -32000, error.message);
    }
    return;
  }

  if (!sawSessionNew && !agent) {
    writeLog("queue-before-session-new", { method: message.method, id: message.id });
  }
  forwardClientLine(JSON.stringify(message));
};

const handleAgentLine = (line) => {
  if (!line.trim()) return;
  try {
    const message = JSON.parse(line);
    if (message.id === internalInitializeId) {
      if (message.error) {
        writeLog("agent-initialize-error", { error: redact(message.error) });
        const errorResponse = {
          jsonrpc: "2.0",
          id: null,
          error: {
            code: -32000,
            message: `Container agent initialize failed: ${message.error.message || JSON.stringify(message.error)}`,
          },
        };
        process.stdout.write(`${JSON.stringify(errorResponse)}\n`);
        return;
      }
      agentInitialized = true;
      agentReady = true;
      writeLog("agent-initialized", { result: redact(message.result) });
      flushPendingClientLines();
      return;
    }
    if (pendingSessionNewLine && message.id) {
      try {
        const pending = JSON.parse(pendingSessionNewLine);
        if (message.id === pending.id && !message.error) {
          const context = pendingSessionContexts.get(message.id);
          pendingSessionContexts.delete(message.id);
          saveSessionContext(message.result?.sessionId, context);
          pendingSessionNewLine = null;
        }
      } catch {
        pendingSessionNewLine = null;
      }
    }
    writeLog("agent-message", {
      id: message.id,
      method: message.method,
      params: redact(message.params),
      result: message.result ? redact(message.result) : undefined,
      error: message.error ? redact(message.error) : undefined,
    });
    process.stdout.write(`${line}\n`);
  } catch {
    writeLog("agent-non-json", { line: line.slice(0, 500) });
    process.stdout.write(`${line}\n`);
  }
};

const splitLines = (buffer, chunk, direction) => {
  buffer += chunk.toString("utf8");
  const lines = buffer.split("\n");
  buffer = lines.pop() ?? "";
  for (const line of lines) {
    if (direction === "client-to-agent") {
      void handleClientLine(line);
    } else {
      handleAgentLine(line);
    }
  }
  return buffer;
};

writeLog("shim-start", {
  agentctl,
  containerCmd,
  agentRuntime,
  acpPackage,
  acpCommand,
  runtimeOnline,
  installRuntime,
  image,
  containerNameSalt,
  stripMcp,
  bridgeMcp,
  codingAssistantDir,
  useXcodeHome,
  xcodeHomeDir,
  xcodeSkillsDir,
  logFile,
  cwd: process.cwd(),
  path: process.env.PATH,
});

process.stdin.on("data", (chunk) => {
  clientBuffer = splitLines(clientBuffer, chunk, "client-to-agent");
});

process.stdin.on("end", () => {
  if (agent) agent.stdin.end();
});

process.on("SIGTERM", () => {
  writeLog("shim-sigterm");
  if (agent) agent.kill("SIGTERM");
  for (const relay of mcpRelays) relay.kill("SIGTERM");
  process.exit(143);
});

process.on("SIGINT", () => {
  writeLog("shim-sigint");
  if (agent) agent.kill("SIGINT");
  for (const relay of mcpRelays) relay.kill("SIGINT");
  process.exit(130);
});
