#!/usr/bin/env node
import http from 'node:http';

function event(level, name, fields={}) {
  console.error(`${new Date().toISOString()} [agentctl-mcp-event] ${JSON.stringify({level,event:name,...fields})}`);
}

const configPath = process.argv[2] || '/etc/agentctl/mcp-bridge.json';
const config = JSON.parse(await (await import('node:fs/promises')).readFile(configPath, 'utf8'));
const server = http.createServer((request, response) => {
  if (request.url === '/.well-known/agentctl-mcp-proxy-health') {
    const data=Buffer.from(JSON.stringify({ok:true,bridge_version:1,pid:process.pid,port:config.port,socket_path:config.socket_path}));
    response.writeHead(200, {'content-type':'application/json','content-length':data.length});
    return response.end(data);
  }
  let finished=false;
  const upstream = http.request({socketPath:config.socket_path, path:request.url, method:request.method, headers:request.headers}, upstreamResponse => {
    response.writeHead(upstreamResponse.statusCode, upstreamResponse.statusMessage, upstreamResponse.headers);
    upstreamResponse.once('end',()=>{ finished=true; });
    upstreamResponse.once('error',()=>{ if (!finished) { finished=true; response.destroy(); } });
    upstreamResponse.pipe(response);
  });
  upstream.on('error', error => {
    if (finished) return;
    finished=true;
    event('error','guest_upstream_unavailable',{code:error.code || 'unknown'});
    if (!response.destroyed) {
      if (!response.headersSent) response.writeHead(502, {'content-type':'application/json'});
      response.end(JSON.stringify({error:`host MCP relay unavailable: ${error.message}`}));
    }
  });
  request.once('aborted',()=>{ if (!finished) { finished=true; upstream.destroy(); } });
  response.once('close',()=>{ if (!response.writableEnded && !finished) { finished=true; upstream.destroy(); } });
  request.pipe(upstream);
});
server.listen(config.port, '127.0.0.1',()=>event('info','guest_proxy_ready',{port:config.port}));
