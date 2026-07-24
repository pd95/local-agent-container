#!/usr/bin/env node
import http from 'node:http';

const configPath = process.argv[2] || '/etc/agentctl/mcp-bridge.json';
const config = JSON.parse(await (await import('node:fs/promises')).readFile(configPath, 'utf8'));
const server = http.createServer((request, response) => {
  if (request.url === '/.well-known/agentctl-mcp-proxy-health') {
    const data=Buffer.from(JSON.stringify({ok:true,bridge_version:1,pid:process.pid,port:config.port,socket_path:config.socket_path}));
    response.writeHead(200, {'content-type':'application/json','content-length':data.length});
    return response.end(data);
  }
  const upstream = http.request({socketPath:config.socket_path, path:request.url, method:request.method, headers:request.headers}, upstreamResponse => {
    response.writeHead(upstreamResponse.statusCode, upstreamResponse.statusMessage, upstreamResponse.headers);
    upstreamResponse.pipe(response);
  });
  upstream.on('error', error => {
    console.error(`[agentctl-mcp-proxy] upstream unavailable (${error.code || 'unknown'})`);
    if (!response.headersSent) response.writeHead(502, {'content-type':'application/json'});
    response.end(JSON.stringify({error:`host MCP relay unavailable: ${error.message}`}));
  });
  request.pipe(upstream);
});
server.listen(config.port, '127.0.0.1');
