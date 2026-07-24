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
fs.writeFileSync(config, JSON.stringify({servers:[{name:'fake',command:process.execPath,args:[path.join(root,'tests/fixtures/fake-mcp-server.mjs')],shared_process:true,env:{AGENTCTL_FAKE_MCP_STARTED:starts,AGENTCTL_FAKE_MCP_CLIENT_RESPONSE:clientResponses}}]}), {mode:0o600});
const relay = spawn(process.execPath, [path.join(root,'mcp/host-relay.mjs'),socket,config,'test-nonce'], {stdio:['ignore','ignore','inherit']});
for (let count=0; count<100 && !fs.existsSync(socket); count++) await new Promise(resolve => setTimeout(resolve, 10));
assert.ok(fs.statSync(socket).isSocket());
function request(method, route, payload, headers={}) {
  return new Promise((resolve,reject) => {
    const req=http.request({socketPath:socket,path:route,method,headers:{...headers,...(payload?{'content-type':'application/json'}:{})}},res=>{
      const chunks=[]; res.on('data',c=>chunks.push(c)); res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks).toString()}));
    }); req.on('error',reject); if(payload)req.write(JSON.stringify(payload)); req.end();
  });
}
const health=await request('GET','/.well-known/agentctl-mcp-health');
assert.equal(JSON.parse(health.body).nonce,'test-nonce');
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
relay.kill('SIGTERM'); await new Promise(resolve=>relay.once('exit',resolve));
fs.rmSync(temporary,{recursive:true,force:true});
console.log('MCP Node tests passed');
