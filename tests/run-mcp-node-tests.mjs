#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawn} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'agentctl-mcp-test-'));
const socket = path.join(temporary, 'relay.sock');
const config = path.join(temporary, 'config.json');
const starts=path.join(temporary,'starts'); const clientResponses=path.join(temporary,'client-responses');
const aborted=path.join(temporary,'http-aborted');
const redirected=path.join(temporary,'http-redirected');
const expectedAuthorizationHash=path.join(temporary,'expected-authorization.sha256');
fs.writeFileSync(expectedAuthorizationHash,`${(await import('node:crypto')).createHash('sha256').update('Bearer configured-secret').digest('hex')}\n`);
const fakeHttp=spawn(process.execPath,[path.join(root,'tests/fixtures/fake-http-mcp-server.mjs')],{env:{...process.env,AGENTCTL_FAKE_HTTP_ABORTED:aborted,AGENTCTL_FAKE_HTTP_REDIRECTED:redirected,AGENTCTL_FAKE_HTTP_EXPECTED_AUTH_HASH_FILE:expectedAuthorizationHash,AGENTCTL_FAKE_HTTP_EXPECTED_TENANT:'configured-tenant'},stdio:['ignore','pipe','inherit']});
const httpPort=Number(await new Promise((resolve,reject)=>{let text='';fakeHttp.stdout.on('data',chunk=>{text+=chunk;if(text.includes('\n'))resolve(text.trim());});fakeHttp.once('error',reject);}));
const unusedServer=http.createServer(); await new Promise(resolve=>unusedServer.listen(0,'127.0.0.1',resolve)); const unusedPort=unusedServer.address().port; await new Promise(resolve=>unusedServer.close(resolve));
const servers=[
  {name:'fake',transport:'stdio',command:process.execPath,args:[path.join(root,'tests/fixtures/fake-mcp-server.mjs')],shared_process:true,env:{AGENTCTL_FAKE_MCP_STARTED:starts,AGENTCTL_FAKE_MCP_CLIENT_RESPONSE:clientResponses}},
  {name:'slow-default',transport:'stdio',command:process.execPath,args:[path.join(root,'tests/fixtures/fake-mcp-server.mjs')],env:{AGENTCTL_FAKE_MCP_DELAY_MS:'1100'}},
  {name:'slow-override',transport:'stdio',command:process.execPath,args:[path.join(root,'tests/fixtures/fake-mcp-server.mjs')],timeout_ms:2000,env:{AGENTCTL_FAKE_MCP_DELAY_MS:'1100'}},
  {name:'http',transport:'http',url:`http://127.0.0.1:${httpPort}/mcp?fixed=1`,resolved_headers:{authorization:'Bearer configured-secret','x-tenant':'configured-tenant'}},
  {name:'redirect',transport:'http',url:`http://127.0.0.1:${httpPort}/redirect`,resolved_headers:{authorization:'Bearer redirect-secret'}},
  {name:'slow',transport:'http',url:`http://127.0.0.1:${httpPort}/slow`,resolved_headers:{}},
  {name:'stall-response',transport:'http',url:`http://127.0.0.1:${httpPort}/stall-response`,resolved_headers:{}},
  {name:'total',transport:'http',url:`http://127.0.0.1:${httpPort}/total`,resolved_headers:{}},
  {name:'tls-failed',transport:'http',url:`https://127.0.0.1:${httpPort}/mcp?fixed=1`,resolved_headers:{}},
  {name:'missing',transport:'http',url:`http://127.0.0.1:${httpPort}/mcp?fixed=1`,resolved_headers:{},missing_credentials:['missing-secret']},
  {name:'failed',transport:'http',url:`http://127.0.0.1:${unusedPort}/mcp`,resolved_headers:{}}
];
fs.writeFileSync(config, JSON.stringify({socket_path:socket,nonce:'test-nonce',container:'test-container',timeout_ms:1000,http_timeouts:{connect:80,headers:80,idle:80,total:500},servers}), {mode:0o600});
let relayLogs='';
const relay = spawn(process.execPath, [path.join(root,'mcp/host-relay.mjs'),config], {stdio:['ignore','ignore','pipe']});
relay.stderr.on('data',chunk=>{relayLogs+=chunk;});
for (let count=0; count<100 && !fs.existsSync(socket); count++) await new Promise(resolve => setTimeout(resolve, 10));
assert.ok(fs.statSync(socket).isSocket());
const portServer=http.createServer();
await new Promise(resolve=>portServer.listen(0,'127.0.0.1',resolve));
const proxyPort=portServer.address().port;
await new Promise(resolve=>portServer.close(resolve));
const proxyConfig=path.join(temporary,'proxy.json');
fs.writeFileSync(proxyConfig,JSON.stringify({port:proxyPort,socket_path:socket}),{mode:0o600});
const proxy=spawn(process.execPath,[path.join(root,'mcp/guest-proxy.mjs'),proxyConfig],{stdio:['ignore','ignore','inherit']});
function request(method, route, payload, headers={}) {
  return new Promise((resolve,reject) => {
    const req=http.request({socketPath:socket,path:route,method,headers:{...headers,...(payload?{'content-type':'application/json'}:{})}},res=>{
      const chunks=[]; res.on('data',c=>chunks.push(c)); res.on('end',()=>resolve({status:res.statusCode,statusMessage:res.statusMessage,headers:res.headers,body:Buffer.concat(chunks).toString()})); res.on('aborted',()=>resolve({status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks).toString(),aborted:true}));
    }); req.on('error',reject); if(payload)req.write(typeof payload === 'string' ? payload : JSON.stringify(payload)); req.end();
  });
}
async function proxyRequest(route) {
  return new Promise((resolve,reject)=>{
    const req=http.request({host:'127.0.0.1',port:proxyPort,path:route},res=>{const chunks=[];res.on('data',c=>chunks.push(c));res.on('end',()=>resolve({status:res.statusCode,body:Buffer.concat(chunks).toString()}));});
    req.on('error',reject);req.end();
  });
}
let proxyHealth;
for(let count=0;count<100;count++){
  try{proxyHealth=await proxyRequest('/.well-known/agentctl-mcp-proxy-health');break;}catch{await new Promise(resolve=>setTimeout(resolve,10));}
}
assert.equal(proxyHealth.status,200);assert.equal(JSON.parse(proxyHealth.body).bridge_version,1);
assert.equal(fs.existsSync(starts),false);
const health=await request('GET','/.well-known/agentctl-mcp-health');
assert.equal(JSON.parse(health.body).nonce,'test-nonce');
assert.equal(JSON.parse(health.body).container,'test-container');
assert.equal(JSON.parse(health.body).bridge_version,1);
assert.deepEqual(JSON.parse(health.body).unavailable_definitions,['missing']);
assert.equal(fs.existsSync(starts),false);
relay.kill('SIGINT');
await new Promise(resolve=>setTimeout(resolve,50));
assert.equal(JSON.parse((await request('GET','/.well-known/agentctl-mcp-health')).body).nonce,'test-nonce');
const [initialized, concurrentInitialized]=await Promise.all([
  request('POST','/mcp/fake',{jsonrpc:'2.0',id:1,method:'initialize',params:{}}),
  request('POST','/mcp/fake',{jsonrpc:'2.0',id:101,method:'initialize',params:{}})
]);
assert.equal(initialized.status,200); assert.equal(JSON.parse(initialized.body).result.serverInfo.name,'fake');
assert.equal(concurrentInitialized.status,200); assert.equal(JSON.parse(concurrentInitialized.body).id,101);
assert.equal(fs.readFileSync(starts,'utf8').trim().split('\n').length,1);
const session=initialized.headers['mcp-session-id']; assert.ok(session);
assert.equal((await request('POST','/mcp/fake',{jsonrpc:'2.0',id:9,method:'tools/list'},{'mcp-session-id':'expired'})).status,404);
const tools=await request('POST','/mcp/fake',{jsonrpc:'2.0',id:2,method:'tools/list'}, {'mcp-session-id':session});
assert.equal(JSON.parse(tools.body).result.tools[0].name,'echo');
const timedOut=await request('POST','/mcp/slow-default',{jsonrpc:'2.0',id:21,method:'tools/list'});
assert.equal(timedOut.status,502); assert.match(timedOut.body,/MCP server response timed out/);
const completedSlowCall=await request('POST','/mcp/slow-override',{jsonrpc:'2.0',id:22,method:'tools/list'});
assert.equal(completedSlowCall.status,200); assert.equal(JSON.parse(completedSlowCall.body).result.tools[0].name,'echo');
assert.match(relayLogs,/response timed out after 1000ms/);
const sseMessage=new Promise((resolve,reject)=>{
  const get=http.request({socketPath:socket,path:'/mcp/fake',method:'GET',headers:{accept:'text/event-stream','mcp-session-id':session}},res=>{
    let body=''; res.on('data',chunk=>{body+=chunk; if(body.includes('notifications/test')){get.destroy();resolve(body);}});
  }); get.on('error',error=>{if(error.code!=='ECONNRESET')reject(error);}); get.end();
});
await new Promise(resolve=>setTimeout(resolve,20));
assert.equal((await request('POST','/mcp/fake',{jsonrpc:'2.0',method:'test/notify'},{'mcp-session-id':session})).status,202);
assert.match(await sseMessage,/notifications\/test/);
assert.equal((await request('POST','/mcp/fake',{jsonrpc:'2.0',id:'server-1',result:{ok:true}},{'mcp-session-id':session})).status,202);
await new Promise(resolve=>setTimeout(resolve,20)); assert.match(fs.readFileSync(clientResponses,'utf8'),/server-1/);
const crashed=await request('POST','/mcp/fake',{jsonrpc:'2.0',id:3,method:'test/crash'}, {'mcp-session-id':session});
assert.equal(crashed.status,502);
await new Promise(resolve=>setTimeout(resolve,500));
const recovered=await request('POST','/mcp/fake',{jsonrpc:'2.0',id:4,method:'tools/list'}, {'mcp-session-id':session});
assert.equal(recovered.status,200); assert.equal(JSON.parse(recovered.body).result.tools[0].name,'echo');
assert.equal((await request('DELETE','/mcp/fake',null,{'mcp-session-id':session})).status,204);
const httpResponse=await request('POST','/mcp/http',{jsonrpc:'2.0',id:20,method:'tools/list'},{authorization:'Bearer client-secret','x-tenant':'client-tenant','connection':'Authorization, X-Tenant','mcp-session-id':'client-session'});
assert.equal(httpResponse.status,207); assert.equal(httpResponse.statusMessage,'Multi-Status'); assert.equal(httpResponse.headers['mcp-session-id'],'client-session'); assert.equal(httpResponse.headers['x-upstream'],'preserved');
const httpBody=JSON.parse(httpResponse.body); assert.equal(httpBody.url,'/mcp?fixed=1'); assert.equal(httpBody.authorization_matches,true); assert.equal(httpBody.tenant_matches,true);
const [getResponse,deleteResponse,parallelOne,parallelTwo]=await Promise.all([
  request('GET','/mcp/http',null,{'last-event-id':'event-42'}), request('DELETE','/mcp/http'),
  request('POST','/mcp/http','one'), request('POST','/mcp/http','two')
]);
assert.equal(JSON.parse(getResponse.body).last_event_id,'event-42'); assert.equal(JSON.parse(getResponse.body).method,'GET'); assert.equal(JSON.parse(deleteResponse.body).method,'DELETE');
assert.equal(JSON.parse(parallelOne.body).body,'one'); assert.equal(JSON.parse(parallelTwo.body).body,'two');
const httpSse=await request('POST','/mcp/http','stream-body',{accept:'text/event-stream'}); assert.equal(httpSse.status,200); assert.match(httpSse.body,/stream-body/);
const slowUpload=await new Promise((resolve,reject)=>{
  const upload=http.request({socketPath:socket,path:'/mcp/http',method:'POST',headers:{'content-length':'5'}},res=>{const chunks=[];res.on('data',c=>chunks.push(c));res.on('end',()=>resolve({status:res.statusCode,body:Buffer.concat(chunks).toString()}));});
  upload.on('error',reject); let sent=0; const timer=setInterval(()=>{upload.write('x');sent++;if(sent===5){clearInterval(timer);upload.end();}},30);
});
assert.equal(slowUpload.status,207); assert.equal(JSON.parse(slowUpload.body).body,'xxxxx');
const stalledUpload=await new Promise((resolve,reject)=>{
  const upload=http.request({socketPath:socket,path:'/mcp/http',method:'POST',headers:{'content-length':'100'}},res=>{const chunks=[];res.on('data',c=>chunks.push(c));res.on('end',()=>resolve({status:res.statusCode,body:Buffer.concat(chunks).toString()}));});
  upload.on('error',reject); upload.write('x');
});
assert.equal(stalledUpload.status,504);
await new Promise(resolve=>{
  const abortedRequest=http.request({socketPath:socket,path:'/mcp/http',method:'POST',headers:{'content-length':'100000'}},()=>{});
  abortedRequest.on('error',()=>resolve()); abortedRequest.write('partial-body'); setTimeout(()=>abortedRequest.destroy(),20); setTimeout(resolve,100);
});
for(let count=0;count<20 && !fs.existsSync(aborted);count++) await new Promise(resolve=>setTimeout(resolve,10));
assert.equal(fs.existsSync(aborted),true);
assert.equal((await request('POST','/mcp/redirect','{}')).status,502);
assert.equal(fs.existsSync(redirected),false);
assert.equal((await request('POST','/mcp/slow','{}')).status,504);
await new Promise(resolve=>{
  const stalled=request('POST','/mcp/stall-response','{}').then(()=>resolve()).catch(()=>resolve()); setTimeout(resolve,200);
});
const totalStarted=Date.now(); await new Promise(resolve=>{request('POST','/mcp/total','{}').then(()=>resolve()).catch(()=>resolve());}); assert.ok(Date.now()-totalStarted>=400);
assert.equal((await request('POST','/mcp/missing','{}')).status,503);
assert.equal((await request('POST','/mcp/failed','{}')).status,502);
assert.equal((await request('POST','/mcp/tls-failed','{}')).status,502);
assert.doesNotMatch(relayLogs,/configured-secret|redirect-secret|client-secret|client-tenant|configured-tenant/);
relay.kill('SIGTERM'); await new Promise(resolve=>relay.once('exit',resolve));
proxy.kill('SIGTERM'); await new Promise(resolve=>proxy.once('exit',resolve));
fakeHttp.kill('SIGTERM'); await new Promise(resolve=>fakeHttp.once('exit',resolve));
fs.rmSync(temporary,{recursive:true,force:true});
console.log('MCP Node tests passed');
