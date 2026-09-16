#!/usr/bin/env node
import readline from 'node:readline';
import fs from 'node:fs';
if (process.env.AGENTCTL_FAKE_MCP_STARTED) {
  fs.appendFileSync(process.env.AGENTCTL_FAKE_MCP_STARTED, `${process.pid}\n`, {mode:0o600});
}
const input = readline.createInterface({input:process.stdin});
let heartbeatTimer;
if (process.env.AGENTCTL_FAKE_MCP_HEARTBEAT) {
  heartbeatTimer=setInterval(()=>fs.appendFileSync(process.env.AGENTCTL_FAKE_MCP_HEARTBEAT,'.'),20);
} else if (process.env.AGENTCTL_FAKE_MCP_IGNORE_EOF || process.env.AGENTCTL_FAKE_MCP_PAUSE_STDIN_AFTER_INITIALIZE) {
  heartbeatTimer=setInterval(()=>{},1000);
}
if (process.env.AGENTCTL_FAKE_MCP_IGNORE_SIGTERM) process.on('SIGTERM',()=>{});
input.on('line', line => {
  const request = JSON.parse(line);
  if (request.method === 'notifications/cancelled') {
    if (process.env.AGENTCTL_FAKE_MCP_CANCELLED) {
      fs.appendFileSync(process.env.AGENTCTL_FAKE_MCP_CANCELLED, `${JSON.stringify(request.params || {})}\n`, {mode:0o600});
    }
    return;
  }
  if (request.method === 'test/crash') process.exit(23);
  if (request.method === 'test/stderr') {
    process.stderr.write('external script failed safely\nsecond diagnostic line\n');
    process.stderr.write(`${'x'.repeat(17000)}\npartial diagnostic`);
  }
  if (request.method === 'test/notify') {
    process.stdout.write(`${JSON.stringify({jsonrpc:'2.0',method:'notifications/test',params:{ok:true}})}\n`);
    process.stdout.write(`${JSON.stringify({jsonrpc:'2.0',id:'server-1',method:'roots/list',params:{}})}\n`);
    return;
  }
  if (!request.method && request.id !== undefined && process.env.AGENTCTL_FAKE_MCP_CLIENT_RESPONSE) {
    fs.appendFileSync(process.env.AGENTCTL_FAKE_MCP_CLIENT_RESPONSE, `${request.id}\n`);
    return;
  }
  if (!Object.prototype.hasOwnProperty.call(request, 'id')) return;
  let result = {};
  if (request.method === 'initialize') result = {protocolVersion:'2025-03-26',capabilities:{tools:{}},serverInfo:{name:'fake',version:'1'}};
  if (request.method === 'tools/list') result = {tools:[{name:'echo',description:'Echo input',inputSchema:{type:'object'}}]};
  if (request.method === 'tools/call') result = {content:[{type:'text',text:JSON.stringify(request.params?.arguments || {})}]};
  const delayMs = request.method === 'test/slow' ? Number.parseInt(process.env.AGENTCTL_FAKE_MCP_DELAY_MS || '0', 10) :
    request.method === 'initialize' ? Number.parseInt(process.env.AGENTCTL_FAKE_MCP_DELAY_INITIALIZE_MS || '0', 10) : 0;
  const respond = () => {
    process.stdout.write(`${JSON.stringify({jsonrpc:'2.0',id:request.id,result})}\n`);
    if (request.method === 'initialize' && process.env.AGENTCTL_FAKE_MCP_PAUSE_STDIN_AFTER_INITIALIZE) input.pause();
  };
  if (Number.isSafeInteger(delayMs) && delayMs > 0) setTimeout(respond, delayMs);
  else respond();
});
input.on('close',()=>{
  if (process.env.AGENTCTL_FAKE_MCP_IGNORE_EOF) return;
  clearInterval(heartbeatTimer);
  if (process.env.AGENTCTL_FAKE_MCP_EOF) fs.writeFileSync(process.env.AGENTCTL_FAKE_MCP_EOF,'eof\n',{mode:0o600});
});
