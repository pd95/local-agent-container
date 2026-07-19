#!/usr/bin/env node
import readline from 'node:readline';
import fs from 'node:fs';
if (process.env.AGENTCTL_FAKE_MCP_STARTED) {
  fs.appendFileSync(process.env.AGENTCTL_FAKE_MCP_STARTED, `${process.pid}\n`, {mode:0o600});
}
const input = readline.createInterface({input:process.stdin});
input.on('line', line => {
  const request = JSON.parse(line);
  if (request.method === 'test/crash') process.exit(23);
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
  process.stdout.write(`${JSON.stringify({jsonrpc:'2.0',id:request.id,result})}\n`);
});
