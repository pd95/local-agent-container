#!/usr/bin/env node
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const [,, configPath] = process.argv;
if (!configPath) {
  console.error('usage: host-relay.mjs CONFIG');
  process.exit(64);
}
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const {socket_path:socketPath, nonce, container:containerName} = config;
const bridgeVersion = 1;
if (!socketPath || !nonce || !containerName) {
  console.error('MCP relay config requires socket_path, nonce, and container');
  process.exit(64);
}
const definitions = new Map(config.servers.map(server => [server.name, server]));
const children = new Set();
const sessions = new Map();
const serverChildren = new Map();
const childQueues = new WeakMap();
const connections = new Set();
const httpAgent = new http.Agent({keepAlive:true});
const httpsAgent = new https.Agent({keepAlive:true});
let shuttingDown = false;
let leaseMissingSince = null;
function log(message) { process.stderr.write(`${new Date().toISOString()} [agentctl-mcp] ${message}\n`); }

function stdioTimeoutMs(definition) {
  const configured = definition.timeout_ms;
  if (Number.isSafeInteger(configured) && configured >= 1000 && configured <= 3600000) return configured;
  const fallback = config.timeout_ms;
  if (Number.isSafeInteger(fallback) && fallback >= 1000 && fallback <= 3600000) return fallback;
  return 30000;
}

function json(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {'content-type':'application/json','content-length':data.length});
  res.end(data);
}

function rpcError(res, status, id, code, message) {
  return json(res,status,{jsonrpc:'2.0',id:id ?? null,error:{code,message}});
}

function originAllowed(origin) {
  if (!origin) return true;
  try { return ['127.0.0.1','localhost','::1'].includes(new URL(origin).hostname); }
  catch { return false; }
}

const hopByHopHeaders = new Set(['connection','keep-alive','proxy-authenticate','proxy-authorization','te','trailer','transfer-encoding','upgrade']);
function filteredHeaders(headers, replacements={}) {
  const connectionTokens = String(headers.connection || '').split(',').map(value => value.trim().toLowerCase()).filter(Boolean);
  const blocked = new Set([...hopByHopHeaders, ...connectionTokens, 'host']);
  const replacementBlocked = new Set([...hopByHopHeaders, 'host', 'content-length']);
  const output = {};
  for (const [name, value] of Object.entries(headers)) {
    const lower = name.toLowerCase();
    if (!blocked.has(lower) && replacements[lower] === undefined && value !== undefined) output[lower]=value;
  }
  for (const [name,value] of Object.entries(replacements)) {
    if (!replacementBlocked.has(name.toLowerCase()) && value !== undefined) output[name.toLowerCase()]=value;
  }
  return output;
}

function proxyFailure(res, status, message) {
  if (res.headersSent) return res.destroy();
  return json(res, status, {error:message});
}

function proxyHttp(req, res, definition) {
  if ((definition.missing_credentials || []).length || (definition.missing_env_vars || []).length ||
      (definition.invalid_credentials || []).length || (definition.invalid_env_vars || []).length) {
    return json(res, 503, {error:'MCP upstream credential is unavailable on the host'});
  }
  const target = new URL(definition.url);
  const targetHostname=target.hostname.startsWith('[') && target.hostname.endsWith(']') ? target.hostname.slice(1,-1) : target.hostname;
  const transport = target.protocol === 'https:' ? https : http;
  const timeouts = {connect:10000,headers:30000,idle:300000,total:86400000,...(config.http_timeouts || {})};
  const configured = definition.resolved_headers || {};
  const headers = filteredHeaders(req.headers, configured);
  headers.host=target.host;
  let finished=false;
  let timedOut=false;
  let idleTimer;
  let headerTimer;
  const clearTimers = () => { clearTimeout(connectTimer); clearTimeout(headerTimer); clearTimeout(idleTimer); clearTimeout(totalTimer); };
  const failTimeout = phase => {
    if (finished) return;
    timedOut=true; finished=true;
    log(`HTTP upstream ${definition.name} ${phase} timeout`);
    upstream.destroy(new Error('timeout'));
    proxyFailure(res,504,'MCP upstream timed out');
  };
  const resetIdle = () => { clearTimeout(idleTimer); idleTimer=setTimeout(() => failTimeout('idle'),timeouts.idle); };
  const upstream = transport.request({
    protocol:target.protocol, hostname:targetHostname, port:target.port || undefined,
    method:req.method, path:`${target.pathname}${target.search}`, headers,
    agent:target.protocol === 'https:' ? httpsAgent : httpAgent
  });
  const connectTimer=setTimeout(() => failTimeout('connect'),timeouts.connect);
  const totalTimer=setTimeout(() => failTimeout('total'),timeouts.total);
  resetIdle();
  upstream.once('finish',()=>{ if (!finished) headerTimer=setTimeout(() => failTimeout('header'),timeouts.headers); });
  upstream.on('socket', socket => {
    if (!socket.connecting) clearTimeout(connectTimer);
    else socket.once(target.protocol === 'https:' ? 'secureConnect' : 'connect', () => clearTimeout(connectTimer));
  });
  upstream.on('response', upstreamResponse => {
    clearTimeout(headerTimer);
    resetIdle();
    if (upstreamResponse.statusCode >= 300 && upstreamResponse.statusCode < 400) {
      upstreamResponse.resume();
      finished=true; clearTimers();
      log(`HTTP upstream ${definition.name} redirect rejected`);
      return json(res,502,{error:'MCP upstream redirect was rejected'});
    }
    const responseHeaders=filteredHeaders(upstreamResponse.headers);
    res.writeHead(upstreamResponse.statusCode, upstreamResponse.statusMessage, responseHeaders);
    upstreamResponse.on('data',resetIdle);
    upstreamResponse.once('end',()=>{ finished=true; clearTimers(); });
    upstreamResponse.once('error',()=>{ if (!finished) { finished=true; clearTimers(); res.destroy(); } });
    upstreamResponse.pipe(res);
  });
  upstream.on('error', error => {
    if (finished) return;
    finished=true; clearTimers();
    if (!timedOut) {
      log(`HTTP upstream ${definition.name} connection failed`);
      proxyFailure(res,502,'MCP upstream is unavailable');
    }
  });
  req.on('data',resetIdle);
  req.once('aborted',()=>{ if (!finished) { finished=true; clearTimers(); upstream.destroy(); } });
  res.once('close',()=>{ if (!res.writableEnded && !finished) { finished=true; clearTimers(); upstream.destroy(); } });
  req.pipe(upstream);
}

const protocolVersions=new Set(['2024-11-05','2025-03-26','2025-06-18']);

function startChild(definition) {
  const existing = definition.shared_process && serverChildren.get(definition.name);
  if (existing && !existing.failed && existing.child.exitCode === null && existing.child.signalCode === null) return existing;
  const baseline = {};
  for (const name of ['PATH', 'HOME', 'TMPDIR', 'USER', 'LOGNAME', 'SHELL', 'LANG']) {
    if (process.env[name] !== undefined) baseline[name] = process.env[name];
  }
  const child = spawn(definition.command, definition.args || [], {
    cwd: definition.cwd || undefined,
    env: {...baseline, ...(definition.inherited_env || {}), ...(definition.env || {})},
    stdio: ['pipe', 'pipe', 'pipe']
  });
  log(`starting server ${definition.name} (pid ${child.pid})`);
  children.add(child);
  const state = {
    child, definition, buffer:Buffer.alloc(0), pending:null, streams:new Map(),
    cachedInitializeResponse:null, initializeRequest:null, initializePromise:null,
    initializedNotified:false, primarySession:null, serverRequests:new Map(), failed:false
  };
  if (definition.shared_process) serverChildren.set(definition.name, state);
  child.stderr.resume();
  child.stdout.on('data', chunk => {
    state.buffer = Buffer.concat([state.buffer, chunk]);
    for (;;) {
      const newline = state.buffer.indexOf('\n');
      if (newline < 0) break;
      const line = state.buffer.subarray(0, newline).toString();
      state.buffer = state.buffer.subarray(newline + 1);
      if (!line.trim()) continue;
      let message;
      try { message = JSON.parse(line); }
      catch {
        if (state.pending) { const pending=state.pending; state.pending=null; pending.reject(new Error('invalid MCP JSON response')); }
        continue;
      }
      if (state.pending && message.id === state.pending.id) {
        const pending=state.pending; state.pending=null; pending.resolve(message);
      } else {
        const event = `event: message\ndata: ${JSON.stringify(message)}\n\n`;
        const isServerRequest = message.id !== undefined && typeof message.method === 'string';
        if (isServerRequest) {
          state.serverRequests.set(String(message.id), state.primarySession);
          const streams = state.streams.get(state.primarySession) || new Set();
          for (const stream of streams) stream.write(event);
        } else {
          for (const streams of state.streams.values()) for (const stream of streams) stream.write(event);
        }
      }
    }
  });
  child.once('exit', (code, signal) => {
    children.delete(child);
    if (serverChildren.get(definition.name) === state) serverChildren.delete(definition.name);
    const activeSessions = [];
    for (const [session, sessionState] of sessions) {
      if (sessionState === state) { activeSessions.push(session); sessions.delete(session); }
    }
    if (state.pending) { const pending=state.pending; state.pending=null; pending.reject(new Error('MCP server exited before responding')); }
    for (const streams of state.streams.values()) for (const stream of streams) stream.end();
    log(`server ${definition.name} exited (code ${code}, signal ${signal || 'none'})`);
    if (!shuttingDown && definition.shared_process && activeSessions.length > 0) {
      setTimeout(async () => {
        if (shuttingDown || serverChildren.has(definition.name)) return;
        log(`restarting shared server ${definition.name} for ${activeSessions.length} active session(s)`);
        const replacement = startChild(definition);
        if (state.initializeRequest) {
          try {
            replacement.initializeRequest=state.initializeRequest;
            replacement.cachedInitializeResponse=await queuedTransact(replacement, state.initializeRequest, stdioTimeoutMs(definition));
            if (state.initializedNotified) {
              await writeChild(replacement, {jsonrpc:'2.0',method:'notifications/initialized'});
              replacement.initializedNotified=true;
            }
          } catch (error) {
            log(`shared server ${definition.name} reinitialize failed: ${error.message}`);
            replacement.child.kill('SIGTERM');
            return;
          }
        }
        for (const session of activeSessions) sessions.set(session, replacement);
      }, 250).unref();
    }
  });
  child.on('error', error => {
    state.failed=true;
    if (serverChildren.get(definition.name) === state) serverChildren.delete(definition.name);
    if (state.pending) { const pending=state.pending; state.pending=null; pending.reject(new Error(`MCP server failed: ${error.message}`)); }
    log(`server ${definition.name} error: ${error.message}`);
  });
  return state;
}

function writeChild(state, payload) {
  return new Promise((resolve, reject) => {
    if (state.failed || state.child.exitCode !== null || state.child.signalCode !== null) return reject(new Error('MCP server is not running'));
    state.child.stdin.write(`${JSON.stringify(payload)}\n`, error => error ? reject(new Error(`MCP server write failed: ${error.message}`)) : resolve());
  });
}

function transact(state, payload, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      if (state.pending?.id === payload.id) state.pending=null;
      log(`server ${state.definition.name} response timed out after ${timeoutMs}ms`);
      reject(new Error('MCP server response timed out'));
    }, timeoutMs);
    state.pending = {
      id:payload.id,
      resolve:value => { clearTimeout(timer); resolve(value); },
      reject:error => { clearTimeout(timer); reject(error); }
    };
    writeChild(state, payload).catch(error => {
      if (state.pending?.id === payload.id) { state.pending=null; clearTimeout(timer); reject(error); }
    });
  });
}

function queuedTransact(state, payload, timeoutMs) {
  const previous = childQueues.get(state) || Promise.resolve();
  const current = previous.catch(() => {}).then(() => transact(state, payload, timeoutMs));
  childQueues.set(state, current);
  current.finally(() => { if (childQueues.get(state) === current) childQueues.delete(state); }).catch(() => {});
  return current;
}

const server = http.createServer(async (req, res) => {
  if (!originAllowed(req.headers.origin)) return rpcError(res,403,null,-32000,'origin is not allowed');
  if (req.url === '/.well-known/agentctl-mcp-health') {
    const unavailableDefinitions=[...definitions.values()].filter(definition =>
      (definition.missing_credentials || []).length || (definition.missing_env_vars || []).length ||
      (definition.invalid_credentials || []).length || (definition.invalid_env_vars || []).length
    ).map(definition=>definition.name).sort();
    return json(res, 200, {ok:true, bridge_version:bridgeVersion, nonce, pid:process.pid, container:containerName, socket_path:socketPath, definitions:[...definitions.keys()].sort(), unavailable_definitions:unavailableDefinitions});
  }
  const match = /^\/mcp\/([A-Za-z0-9][A-Za-z0-9._-]{0,62})$/.exec(new URL(req.url, 'http://localhost').pathname);
  if (!match) return json(res, 404, {error:'unknown MCP route'});
  const definition = definitions.get(match[1]);
  if (!definition) return json(res, 503, {error:`MCP server is not configured: ${match[1]}`});
  if ((definition.transport || 'stdio') === 'http') {
    log(`request ${req.method} /mcp/${match[1]} (http)`);
    return proxyHttp(req,res,definition);
  }
  const sessionId = req.headers['mcp-session-id'];
  if (req.method === 'DELETE') {
    if (sessionId && !sessions.has(sessionId)) return rpcError(res,404,null,-32001,'unknown or expired MCP session');
    const state = sessionId && sessions.get(sessionId);
    if (sessionId) sessions.delete(sessionId);
    if (state && state.primarySession === sessionId) {
      state.primarySession=[...sessions.entries()].find(([,candidate]) => candidate === state)?.[0] || null;
    }
    if (state && !state.definition.shared_process && ![...sessions.values()].includes(state)) state.child.kill('SIGTERM');
    res.writeHead(204); return res.end();
  }
  if (req.method === 'GET') {
    if (!(req.headers.accept || '').includes('text/event-stream')) return rpcError(res,406,null,-32000,'GET requires Accept: text/event-stream');
    const state = sessionId && sessions.get(sessionId);
    if (!state) return json(res, 404, {error:'unknown or expired MCP session'});
    res.writeHead(200, {'content-type':'text/event-stream','cache-control':'no-cache','connection':'keep-alive'});
    res.write(': connected\n\n');
    let streams = state.streams.get(sessionId);
    if (!streams) { streams=new Set(); state.streams.set(sessionId, streams); }
    streams.add(res);
    req.on('close', () => { streams.delete(res); if (streams.size === 0) state.streams.delete(sessionId); });
    return;
  }
  if (req.method !== 'POST') return json(res, 405, {error:'use GET, POST, or DELETE'});
  const accept=req.headers.accept || '*/*';
  if (!accept.includes('*/*') && !accept.includes('application/json') && !accept.includes('text/event-stream')) return rpcError(res,406,null,-32000,'unsupported Accept header');
  const protocolVersion=req.headers['mcp-protocol-version'];
  if (protocolVersion && !protocolVersions.has(protocolVersion)) return rpcError(res,400,null,-32600,'unsupported MCP protocol version');
  log(`request ${req.method} /mcp/${match[1]}`);
  const chunks = []; let size = 0;
  for await (const chunk of req) { size += chunk.length; if (size > 8 * 1024 * 1024) return rpcError(res,413,null,-32600,'request too large'); chunks.push(chunk); }
  let payload; try { payload = JSON.parse(Buffer.concat(chunks).toString()); } catch { return rpcError(res,400,null,-32700,'invalid JSON'); }
  log(`message ${definition.name} ${payload.method || 'response'}`);
  if (sessionId && !sessions.has(sessionId)) return json(res, 404, {error:'unknown or expired MCP session'});
  let state = sessionId && sessions.get(sessionId);
  if (!state) state = startChild(definition);
  const nextSession = sessionId || randomUUID();
  sessions.set(nextSession, state);
  if (!state.primarySession) state.primarySession=nextSession;
  const isClientResponse = payload.id !== undefined && !payload.method && (Object.hasOwn(payload,'result') || Object.hasOwn(payload,'error'));
  if (isClientResponse) {
    const owner=state.serverRequests.get(String(payload.id));
    if (!owner || owner !== nextSession) return rpcError(res,409,payload.id,-32002,'server request response belongs to another session');
    state.serverRequests.delete(String(payload.id));
    try { await writeChild(state, payload); res.writeHead(202, {'mcp-session-id':nextSession}); return res.end(); }
    catch (error) { return json(res, 502, {error:error.message}); }
  }
  if (definition.shared_process && payload.method === 'initialize' && state.cachedInitializeResponse) {
    res.setHeader('mcp-session-id', nextSession);
    return json(res, 200, {...state.cachedInitializeResponse, id:payload.id});
  }
  if (definition.shared_process && payload.method === 'initialize' && state.initializePromise) {
    try {
      const cached = await state.initializePromise;
      res.setHeader('mcp-session-id', nextSession);
      return json(res, 200, {...cached,id:payload.id});
    } catch (error) { return json(res, 502, {error:error.message}); }
  }
  if (definition.shared_process && payload.method === 'initialize') state.initializeRequest=payload;
  if (definition.shared_process && payload.method === 'notifications/initialized') {
    if (state.initializedNotified) {
      res.writeHead(202, {'mcp-session-id':nextSession}); return res.end();
    }
    state.initializedNotified=true;
  }
  if (!Object.prototype.hasOwnProperty.call(payload, 'id')) {
    try { await writeChild(state, payload); res.writeHead(202, {'mcp-session-id':nextSession}); return res.end(); }
    catch (error) { return json(res, 502, {error:error.message}); }
  }
  try {
    let responsePromise = queuedTransact(state, payload, stdioTimeoutMs(definition));
    if (definition.shared_process && payload.method === 'initialize') state.initializePromise=responsePromise;
    const response = await responsePromise;
    if (definition.shared_process && payload.method === 'initialize') {
      state.cachedInitializeResponse=response; state.initializePromise=null;
    }
    res.setHeader('mcp-session-id', nextSession);
    if ((req.headers.accept || '').includes('text/event-stream')) {
      res.writeHead(200, {'content-type':'text/event-stream','cache-control':'no-cache'});
      return res.end(`event: message\ndata: ${JSON.stringify(response)}\n\n`);
    }
    return json(res, 200, response);
  } catch (error) { state.initializePromise=null; log(`server ${definition.name} request failed: ${error.message}`); state.child.kill('SIGTERM'); sessions.delete(nextSession); return json(res, 502, {error:error.message}); }
});

function shutdown(signal='supervisor') {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`relay shutting down (${signal})`);
  server.close(() => { try { fs.unlinkSync(socketPath); } catch {} process.exit(0); });
  for (const child of children) child.kill('SIGTERM');
  httpAgent.destroy();
  httpsAgent.destroy();
  setTimeout(() => {
    for (const connection of connections) connection.destroy();
    try { fs.unlinkSync(socketPath); } catch {}
    process.exit(1);
  }, 2000);
}
// The relay is container-scoped, not attached to an interactive agent session.
// Only the verified supervisor terminates it with SIGTERM. In particular, do
// not turn a terminal SIGINT from one client into an outage for other clients.
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => log('ignoring interactive SIGINT'));
process.on('SIGHUP', () => log('ignoring terminal SIGHUP'));
if (config.ephemeral_env) {
  setInterval(() => {
    let live=false;
    try {
      for (const entry of fs.readdirSync(config.lease_dir)) {
        if (!entry.startsWith(config.lease_prefix) || !entry.endsWith('.json')) continue;
        try {
          const lease=JSON.parse(fs.readFileSync(`${config.lease_dir}/${entry}`,'utf8'));
          process.kill(lease.owner_pid, 0);
          const started=execFileSync('ps',['-p',String(lease.owner_pid),'-o','lstart='],{encoding:'utf8'}).trim();
          if (lease.owner_started && started === lease.owner_started) { live=true; break; }
        } catch {}
      }
    } catch {}
    if (live) leaseMissingSince=null;
    else if (leaseMissingSince === null) leaseMissingSince=Date.now();
    else if (Date.now()-leaseMissingSince > 3000) { log('no live leases remain; shutting down ephemeral relay'); shutdown(); }
  }, 1000).unref();
}
server.on('error', error => { console.error(`MCP relay: ${error.message}`); process.exit(1); });
server.on('connection', connection => {
  connections.add(connection);
  connection.once('close', () => connections.delete(connection));
});
// The containing host directory is owner-only (0700). The socket itself must
// permit the explicitly mounted guest UID, which is not the macOS host UID.
server.listen(socketPath, () => { fs.chmodSync(socketPath, 0o666); log('relay ready'); });
