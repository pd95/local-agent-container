#!/usr/bin/env node
import fs from 'node:fs';

const records=[];
let sequence=0;
let latestStderr=null;
let latestTimeout=null;

function summary(payload) {
  const method=typeof payload.method === 'string' ? `${payload.method} ` : 'server response ';
  const cancellation=payload.cancellation === 'sent' ? '; cancellation sent' :
    payload.cancellation === 'failed' ? '; cancellation failed' :
    payload.cancellation === 'not_permitted' ? '; cancellation not permitted' : '';
  const serverAction=payload.server_action === 'preserved' ? '; server preserved' :
    payload.server_action === 'stopping' ? '; server stopping' : '';
  switch (payload.event) {
    case 'stdio_server_exited': return `server exited (code ${payload.code ?? 'unknown'}, signal ${payload.signal || 'none'})${payload.reason ? ` during ${payload.reason}` : ''}`;
    case 'stdio_response_timeout': return `${method}timed out after ${payload.timeout_ms ?? 'unknown'}ms${payload.timeout_source ? ` (${payload.timeout_source})` : ''}${cancellation}${serverAction}`;
    case 'stdio_client_disconnected': return `${method}cancelled after client disconnect${cancellation}${serverAction}`;
    case 'stdio_server_stop_escalated': return `server shutdown escalated to ${payload.signal || 'signal'}${payload.reason ? ` (${payload.reason})` : ''}`;
    case 'stdio_request_failed': return 'server request failed';
    case 'stdio_reinitialize_failed': return 'shared server reinitialization failed';
    case 'stdio_spawn_error': return `server process failed (${payload.code || 'unknown'})`;
    case 'http_credentials_unavailable': return 'HTTP upstream credentials are unavailable';
    case 'http_response': return `HTTP upstream returned status ${payload.status ?? 'unknown'}`;
    case 'http_timeout': return `HTTP upstream ${payload.phase || 'request'} timeout`;
    case 'http_redirect_rejected': return `HTTP upstream redirect rejected (status ${payload.status ?? 'unknown'})`;
    case 'http_connection_failed': return `HTTP upstream connection failed (${payload.code || 'unknown'})`;
    case 'guest_upstream_unavailable': return `guest proxy could not reach host relay (${payload.code || 'unknown'})`;
    case 'relay_error': return `host relay failed (${payload.code || 'unknown'})`;
    default: return null;
  }
}

for (const path of process.argv.slice(2)) {
  let text;
  try { text=fs.readFileSync(path,'utf8'); } catch (error) { if (error.code==='ENOENT') continue; throw error; }
  for (const line of text.split('\n')) {
    const eventMatch=/^(\S+) \[agentctl-mcp-event\] (\{.*\})$/.exec(line);
    if (eventMatch) {
      try {
        const payload=JSON.parse(eventMatch[2]);
        if (payload.level !== 'error') continue;
        const message=summary(payload);
        if (message) {
          const record={timestamp:eventMatch[1],server:payload.server || 'bridge',message,sequence:sequence++};
          if (payload.event === 'stdio_response_timeout') latestTimeout=record;
          else records.push(record);
        }
      } catch {}
      continue;
    }
    const stderrMatch=/^(\S+) \[agentctl-mcp-stderr\] (\{.*\})$/.exec(line);
    if (stderrMatch) {
      try {
        const payload=JSON.parse(stderrMatch[2]);
        latestStderr={timestamp:stderrMatch[1],server:payload.server || 'unknown'};
      } catch {}
    }
  }
}
records.sort((a,b)=>a.timestamp.localeCompare(b.timestamp) || a.sequence-b.sequence);
process.stdout.write(JSON.stringify({
  errors:records.slice(-5).map(({sequence:_,...item})=>item),
  latest_timeout:latestTimeout ? (({sequence:_,...item})=>item)(latestTimeout) : null,
  latest_stderr:latestStderr
}));
