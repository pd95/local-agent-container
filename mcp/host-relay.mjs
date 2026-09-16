#!/usr/bin/env node
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import {StringDecoder} from 'node:string_decoder';
import {RotatingLog, writeEvent, writeServerStderr} from './rotating-log.mjs';

const [,, configPath] = process.argv;
if (!configPath) {
  console.error('usage: host-relay.mjs CONFIG');
  process.exit(64);
}
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const {socket_path:socketPath, nonce, container:containerName} = config;
const managedLog = new RotatingLog(config.log_path, config.log_max_bytes);
const bridgeVersion = 1;
if (!socketPath || !nonce || !containerName) {
  console.error('MCP relay config requires socket_path, nonce, and container');
  process.exit(64);
}
const definitions = new Map(config.servers.map(server => [server.name, server]));
const childStates = new Set();
const sessions = new Map();
const serverChildren = new Map();
const childQueues = new WeakMap();
const connections = new Set();
const httpAgent = new http.Agent({keepAlive:true});
const httpsAgent = new https.Agent({keepAlive:true});
const DEFAULT_STDIO_TIMEOUT_MS = 360000;
const CHILD_EOF_GRACE_MS = 1500;
const CHILD_TERM_GRACE_MS = 500;
const RELAY_SHUTDOWN_DEADLINE_MS = 2500;
let shuttingDown = false;
let leaseMissingSince = null;
let nextRelayRequestId = 1;
function event(level, name, fields={}) { writeEvent(managedLog,level,name,fields); }

function relayRequestId() {
  const id=nextRelayRequestId;
  nextRelayRequestId = nextRelayRequestId === Number.MAX_SAFE_INTEGER ? 1 : nextRelayRequestId + 1;
  return id;
}

function stdioTimeout(definition) {
  const configured = definition.timeout_ms;
  if (Number.isSafeInteger(configured) && configured >= 1000 && configured <= 3600000) {
    return {timeoutMs:configured, timeoutSource:'definition'};
  }
  const fallback = config.timeout_ms;
  if (Number.isSafeInteger(fallback) && fallback >= 1000 && fallback <= 3600000) {
    return {timeoutMs:fallback, timeoutSource:'default'};
  }
  return {timeoutMs:DEFAULT_STDIO_TIMEOUT_MS, timeoutSource:'default'};
}

class StdioResponseTimeoutError extends Error {
  constructor() { super('MCP server response timed out'); this.name='StdioResponseTimeoutError'; }
}

class StdioClientDisconnectedError extends Error {
  constructor() { super('MCP client disconnected'); this.name='StdioClientDisconnectedError'; }
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
    event('error','http_credentials_unavailable',{server:definition.name,status:503});
    return json(res, 503, {error:'MCP upstream credential is unavailable on the host'});
  }
  const started=Date.now();
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
    event('error','http_timeout',{server:definition.name,phase});
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
      event('error','http_redirect_rejected',{server:definition.name,status:upstreamResponse.statusCode});
      return json(res,502,{error:'MCP upstream redirect was rejected'});
    }
    event(upstreamResponse.statusCode >= 400 ? 'error' : 'info','http_response',{
      server:definition.name,status:upstreamResponse.statusCode,duration_ms:Date.now()-started
    });
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
      event('error','http_connection_failed',{server:definition.name,code:error.code || 'unknown'});
      proxyFailure(res,502,'MCP upstream is unavailable');
    }
  });
  req.on('data',resetIdle);
  req.once('aborted',()=>{ if (!finished) { finished=true; clearTimers(); upstream.destroy(); } });
  res.once('close',()=>{ if (!res.writableEnded && !finished) { finished=true; clearTimers(); upstream.destroy(); } });
  req.pipe(upstream);
}

const protocolVersions=new Set(['2024-11-05','2025-03-26','2025-06-18']);

function childRunning(state) {
  return !state.failed && state.child.exitCode === null && state.child.signalCode === null;
}

function waitForChildExit(state, timeoutMs) {
  return new Promise(resolve => {
    if (!childRunning(state)) return resolve(true);
    let settled=false;
    let timer;
    const finish = exited => {
      if (settled) return;
      settled=true;
      clearTimeout(timer);
      state.child.removeListener('exit',onExit);
      resolve(exited);
    };
    const onExit = () => finish(true);
    state.child.once('exit',onExit);
    if (!childRunning(state)) return finish(true);
    timer=setTimeout(() => finish(false),timeoutMs);
  });
}

function stopChild(state, reason) {
  if (state.stopPromise) return state.stopPromise;
  state.expectedExit=true;
  state.stopReason=reason;
  state.stopPromise=(async () => {
    if (!childRunning(state)) return;
    event('info','stdio_server_stop_requested',{server:state.definition.name,reason,phase:'stdin_eof'});
    try { state.child.stdin.end(); } catch {}
    if (await waitForChildExit(state,CHILD_EOF_GRACE_MS)) return;
    state.stopSignals.add('SIGTERM');
    event('error','stdio_server_stop_escalated',{server:state.definition.name,reason,signal:'SIGTERM'});
    state.child.kill('SIGTERM');
    if (await waitForChildExit(state,CHILD_TERM_GRACE_MS)) return;
    state.stopSignals.add('SIGKILL');
    event('error','stdio_server_stop_escalated',{server:state.definition.name,reason,signal:'SIGKILL'});
    state.child.kill('SIGKILL');
    await waitForChildExit(state,250);
  })();
  return state.stopPromise;
}

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
  event('info','stdio_server_started',{server:definition.name,pid:child.pid ?? null});
  const state = {
    child, definition, buffer:Buffer.alloc(0), pending:null, streams:new Map(),
    cachedInitializeResponse:null, initializeRequest:null, initializePromise:null,
    initializedNotified:false, primarySession:null, serverRequests:new Map(), failed:false, expectedExit:false,
    restartAllowed:true, stopPromise:null, stopReason:null, stopSignals:new Set()
  };
  childStates.add(state);
  if (definition.shared_process) serverChildren.set(definition.name, state);
  child.stdin.on('error', error => {
    if (!state.expectedExit && !shuttingDown) event('error','stdio_stdin_error',{server:definition.name,code:error.code || 'unknown'});
  });
  const stderrDecoder = new StringDecoder('utf8');
  let stderrBuffer='';
  let stderrDropping=false;
  const stderrLimit=16384;
  const emitStderr = (line,truncated=false) => writeServerStderr(managedLog,definition.name,child.pid ?? null,line,truncated);
  child.stderr.on('data', chunk => {
    stderrBuffer += stderrDecoder.write(chunk);
    for (;;) {
      const newline=stderrBuffer.indexOf('\n');
      if (newline < 0) break;
      const line=stderrBuffer.slice(0,newline).replace(/\r$/,'');
      stderrBuffer=stderrBuffer.slice(newline+1);
      if (!stderrDropping) emitStderr(line.length > stderrLimit ? line.slice(0,stderrLimit) : line,line.length > stderrLimit);
      stderrDropping=false;
    }
    if (!stderrDropping && stderrBuffer.length > stderrLimit) {
      emitStderr(stderrBuffer.slice(0,stderrLimit),true);
      stderrBuffer=''; stderrDropping=true;
    } else if (stderrDropping && stderrBuffer.length > stderrLimit) stderrBuffer='';
  });
  child.stderr.once('end',()=>{
    stderrBuffer += stderrDecoder.end();
    if (stderrBuffer && !stderrDropping) emitStderr(stderrBuffer.replace(/\r$/,''));
  });
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
      const isResponse = message.id !== undefined && typeof message.method !== 'string' &&
        (Object.hasOwn(message,'result') || Object.hasOwn(message,'error'));
      if (isResponse && state.pending && message.id === state.pending.id) {
        const pending=state.pending; state.pending=null; pending.resolve(message);
      } else {
        if (isResponse) {
          event('info','stdio_late_response_discarded',{server:definition.name});
          continue;
        }
        const streamEvent = `event: message\ndata: ${JSON.stringify(message)}\n\n`;
        const isServerRequest = message.id !== undefined && typeof message.method === 'string';
        if (isServerRequest) {
          state.serverRequests.set(String(message.id), state.primarySession);
          const streams = state.streams.get(state.primarySession) || new Set();
          for (const stream of streams) stream.write(streamEvent);
        } else {
          for (const streams of state.streams.values()) for (const stream of streams) stream.write(streamEvent);
        }
      }
    }
  });
  child.once('exit', (code, signal) => {
    childStates.delete(state);
    if (serverChildren.get(definition.name) === state) serverChildren.delete(definition.name);
    const activeSessions = [];
    for (const [session, sessionState] of sessions) {
      if (sessionState === state) { activeSessions.push(session); sessions.delete(session); }
    }
    if (state.pending) { const pending=state.pending; state.pending=null; pending.reject(new Error('MCP server exited before responding')); }
    for (const streams of state.streams.values()) for (const stream of streams) stream.end();
    const requestedSignal=signal && state.stopSignals.has(signal);
    const expected=(shuttingDown || state.expectedExit) && ((code === 0 && !signal) || requestedSignal);
    event(expected ? 'info' : 'error','stdio_server_exited',{
      server:definition.name,code,signal:signal || 'none',expected,reason:state.stopReason || null
    });
    if (!shuttingDown && state.restartAllowed && definition.shared_process && activeSessions.length > 0) {
      setTimeout(async () => {
        if (shuttingDown || serverChildren.has(definition.name)) return;
        event('info','stdio_server_restarting',{server:definition.name,sessions:activeSessions.length});
        const replacement = startChild(definition);
        if (state.initializeRequest) {
          try {
            replacement.initializeRequest=state.initializeRequest;
            replacement.cachedInitializeResponse=await queuedTransact(replacement, state.initializeRequest, stdioTimeout(definition));
            if (state.initializedNotified) {
              await writeChild(replacement, {jsonrpc:'2.0',method:'notifications/initialized'});
              replacement.initializedNotified=true;
            }
          } catch (error) {
            event('error','stdio_reinitialize_failed',{server:definition.name});
            void stopChild(replacement,'reinitialize_failed');
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
    event('error','stdio_spawn_error',{server:definition.name,code:error.code || 'unknown'});
  });
  return state;
}

function writeChild(state, payload) {
  return new Promise((resolve, reject) => {
    if (state.failed || state.child.exitCode !== null || state.child.signalCode !== null) return reject(new Error('MCP server is not running'));
    state.child.stdin.write(`${JSON.stringify(payload)}\n`, error => error ? reject(new Error(`MCP server write failed: ${error.message}`)) : resolve());
  });
}

function requestCancellation(state, requestId, reason) {
  if (!childRunning(state)) return false;
  try {
    state.child.stdin.write(`${JSON.stringify({jsonrpc:'2.0',method:'notifications/cancelled',params:{requestId,reason}})}\n`, error => {
      if (error) event('error','stdio_cancellation_write_failed',{server:state.definition.name,code:error.code || 'unknown'});
    });
    return true;
  } catch (error) {
    event('error','stdio_cancellation_write_failed',{server:state.definition.name,code:error.code || 'unknown'});
    return false;
  }
}

function transact(state, payload, timeoutConfig, abortSignal) {
  return new Promise((resolve, reject) => {
    const {timeoutMs,timeoutSource}=timeoutConfig;
    const clientId=payload.id;
    const wireId=relayRequestId();
    const forwarded={...payload,id:wireId};
    let settled=false;
    let requestIssued=false;
    let timer;
    const cleanup = () => {
      clearTimeout(timer);
      abortSignal?.removeEventListener('abort',onAbort);
    };
    const rejectPending = error => {
      if (settled) return;
      settled=true; cleanup(); reject(error);
    };
    const cancelPending = async cause => {
      if (settled) return;
      settled=true;
      if (state.pending?.id === wireId) state.pending=null;
      cleanup();
      let cancellation='not_required';
      let serverAction='preserved';
      if (payload.method === 'initialize') {
        cancellation='not_permitted';
        serverAction='stopping';
        state.restartAllowed=false;
        void stopChild(state,`${cause}_during_initialize`);
      } else if (requestIssued) {
        cancellation=requestCancellation(state,wireId,cause === 'timeout' ? 'Agentctl response deadline exceeded' : 'MCP client disconnected') ? 'requested' : 'failed';
      }
      const fields={server:state.definition.name,method:payload.method || 'request',cancellation,server_action:serverAction};
      if (cause === 'timeout') {
        event('error','stdio_response_timeout',{...fields,timeout_ms:timeoutMs,timeout_source:timeoutSource});
        reject(new StdioResponseTimeoutError());
      } else {
        event('error','stdio_client_disconnected',fields);
        reject(new StdioClientDisconnectedError());
      }
    };
    const onAbort = () => { void cancelPending('client_disconnect'); };
    state.pending = {
      id:wireId,
      resolve:value => {
        if (settled) return;
        settled=true; cleanup(); resolve({...value,id:clientId});
      },
      reject:rejectPending
    };
    if (abortSignal?.aborted) return void cancelPending('client_disconnect');
    abortSignal?.addEventListener('abort',onAbort,{once:true});
    timer=setTimeout(() => { void cancelPending('timeout'); },timeoutMs);
    requestIssued=true;
    writeChild(state, forwarded).catch(error => {
      if (state.pending?.id === wireId) state.pending=null;
      rejectPending(error);
    });
  });
}

function queuedTransact(state, payload, timeoutConfig, abortSignal) {
  const previous = childQueues.get(state) || Promise.resolve();
  const current = previous.catch(() => {}).then(() => transact(state, payload, timeoutConfig, abortSignal));
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
    event('info','request_received',{server:match[1],transport:'http',method:req.method});
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
    if (state && !state.definition.shared_process && ![...sessions.values()].includes(state)) void stopChild(state,'session_closed');
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
  const requestStarted=Date.now();
  event('info','request_received',{server:match[1],transport:'stdio',method:req.method});
  const requestAbort=new AbortController();
  const abortRequest=()=>requestAbort.abort();
  req.once('aborted',abortRequest);
  res.once('close',()=>{ if (!res.writableEnded) abortRequest(); });
  const chunks = []; let size = 0;
  try {
    for await (const chunk of req) { size += chunk.length; if (size > 8 * 1024 * 1024) return rpcError(res,413,null,-32600,'request too large'); chunks.push(chunk); }
  } catch (error) {
    if (requestAbort.signal.aborted || req.aborted || error.code === 'ECONNRESET') return;
    if (!res.destroyed) return rpcError(res,400,null,-32600,'request body could not be read');
    return;
  }
  let payload; try { payload = JSON.parse(Buffer.concat(chunks).toString()); } catch { return rpcError(res,400,null,-32700,'invalid JSON'); }
  event('info','stdio_message',{server:definition.name,method:typeof payload.method === 'string' ? payload.method : 'response'});
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
    } catch (error) {
      return json(res, error instanceof StdioResponseTimeoutError ? 504 : 502, {error:error.message});
    }
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
    let responsePromise = queuedTransact(state, payload, stdioTimeout(definition), requestAbort.signal);
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
    event('info','stdio_response',{server:definition.name,duration_ms:Date.now()-requestStarted});
    return json(res, 200, response);
  } catch (error) {
    state.initializePromise=null;
    if (error instanceof StdioClientDisconnectedError) return;
    if (error instanceof StdioResponseTimeoutError) {
      if (res.destroyed) return;
      return json(res, 504, {error:error.message});
    }
    event('error','stdio_request_failed',{server:definition.name,method:payload.method || 'request'});
    void stopChild(state,'request_failed');
    sessions.delete(nextSession);
    if (!res.destroyed) return json(res, 502, {error:error.message});
  }
});

function shutdown(signal='supervisor') {
  if (shuttingDown) return;
  shuttingDown = true;
  event('info','relay_stopping',{signal});
  httpAgent.destroy();
  httpsAgent.destroy();
  let finished=false;
  let serverClosed=false;
  const childStops=Promise.all([...childStates].map(state => stopChild(state,'relay_shutdown')));
  const finish = exitCode => {
    if (finished) return;
    finished=true;
    clearTimeout(deadline);
    try { fs.unlinkSync(socketPath); } catch {}
    process.exit(exitCode);
  };
  server.close(() => { serverClosed=true; });
  const completion=setInterval(() => {
    if (serverClosed && [...childStates].every(state => !childRunning(state))) {
      clearInterval(completion);
      void childStops.then(() => finish(0));
    }
  },25);
  const deadline=setTimeout(() => {
    clearInterval(completion);
    for (const connection of connections) connection.destroy();
    for (const state of childStates) {
      if (!childRunning(state)) continue;
      state.stopSignals.add('SIGKILL');
      event('error','stdio_server_stop_escalated',{server:state.definition.name,reason:'relay_shutdown_deadline',signal:'SIGKILL'});
      state.child.kill('SIGKILL');
    }
    finish(1);
  }, RELAY_SHUTDOWN_DEADLINE_MS);
}
// The relay is container-scoped, not attached to an interactive agent session.
// Only the verified supervisor terminates it with SIGTERM. In particular, do
// not turn a terminal SIGINT from one client into an outage for other clients.
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => event('info','signal_ignored',{signal:'SIGINT'}));
process.on('SIGHUP', () => event('info','signal_ignored',{signal:'SIGHUP'}));
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
    else if (Date.now()-leaseMissingSince > 3000) { event('info','leases_expired'); shutdown(); }
  }, 1000).unref();
}
server.on('error', error => { event('error','relay_error',{code:error.code || 'unknown'}); process.exit(1); });
server.on('connection', connection => {
  connections.add(connection);
  connection.once('close', () => connections.delete(connection));
});
// The containing host directory is owner-only (0700). The socket itself must
// permit the explicitly mounted guest UID, which is not the macOS host UID.
server.listen(socketPath, () => { fs.chmodSync(socketPath, 0o666); event('info','relay_ready',{pid:process.pid}); });
