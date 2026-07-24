#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs';
import {createHash} from 'node:crypto';

const abortMarker=process.env.AGENTCTL_FAKE_HTTP_ABORTED || '';
const redirectMarker=process.env.AGENTCTL_FAKE_HTTP_REDIRECTED || '';
const expectedAuthorizationHashFile=process.env.AGENTCTL_FAKE_HTTP_EXPECTED_AUTH_HASH_FILE || '';
const configuredExpectedAuthorization=process.env.AGENTCTL_FAKE_HTTP_EXPECTED_AUTH || '';
const expectedTenant=process.env.AGENTCTL_FAKE_HTTP_EXPECTED_TENANT || '';
const server=http.createServer(async (req,res) => {
  if (req.url === '/redirect') {
    res.writeHead(302,{location:`http://127.0.0.1:${server.address().port}/credential-leak`});
    return res.end();
  }
  if (req.url === '/credential-leak') { if (redirectMarker) fs.appendFileSync(redirectMarker,'followed\n'); res.end('{}'); return; }
  if (req.url === '/slow') return setTimeout(()=>res.end('{}'),500);
  if (req.url === '/stall-response') { res.writeHead(200,{'content-type':'text/event-stream'}); res.write('data: partial\n'); return setTimeout(()=>res.end('\n'),500); }
  if (req.url === '/total') { res.writeHead(200,{'content-type':'text/event-stream'}); const timer=setInterval(()=>res.write('data: active\n\n'),30); return setTimeout(()=>{clearInterval(timer);res.end();},1000); }
  if (req.url !== '/mcp?fixed=1') { res.writeHead(404); return res.end('not found'); }
  const chunks=[];
  req.on('aborted',()=>{ if (abortMarker) fs.appendFileSync(abortMarker,'aborted\n'); });
  try { for await (const chunk of req) chunks.push(chunk); }
  catch (error) { if (error.code === 'ECONNRESET') return; throw error; }
  const body=Buffer.concat(chunks).toString();
  if ((req.headers.accept || '').includes('text/event-stream')) {
    res.writeHead(200,{'content-type':'text/event-stream','mcp-session-id':req.headers['mcp-session-id'] || 'fake-http-session','x-upstream':'preserved'});
    res.write('event: message\n');
    return setTimeout(()=>res.end(`data: ${body}\n\n`),20);
  }
  res.writeHead(207,{'content-type':'application/json','mcp-session-id':req.headers['mcp-session-id'] || 'fake-http-session','x-upstream':'preserved'});
  const authorizationMatches=expectedAuthorizationHashFile
    ? createHash('sha256').update(req.headers.authorization || '').digest('hex')===fs.readFileSync(expectedAuthorizationHashFile,'utf8')
    : req.headers.authorization===configuredExpectedAuthorization;
  res.end(JSON.stringify({method:req.method,url:req.url,last_event_id:req.headers['last-event-id'] || null,authorization_matches:authorizationMatches,tenant_matches:expectedTenant ? req.headers['x-tenant']===expectedTenant : null,body}));
});
server.listen(0,'127.0.0.1',()=>process.stdout.write(`${server.address().port}\n`));
process.on('SIGTERM',()=>server.close(()=>process.exit(0)));
