#!/usr/bin/env node
const [,,endpoint,tool,argument='{}']=process.argv;
let session;
async function request(method,body) {
  const response=await fetch(endpoint,{method,headers:{accept:'application/json','content-type':'application/json',...(session?{'mcp-session-id':session}:{})},...(body?{body:JSON.stringify(body)}:{})});
  if (!response.ok) throw new Error(`MCP HTTP ${response.status}: ${await response.text()}`);
  session=response.headers.get('mcp-session-id') || session;
  return response.status===202 || response.status===204 ? null : response.json();
}
try {
  await request('POST',{jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-03-26',capabilities:{},clientInfo:{name:'artifact-integration-test',version:'1'}}});
  await request('POST',{jsonrpc:'2.0',method:'notifications/initialized'});
  const response=await request('POST',{jsonrpc:'2.0',id:2,method:'tools/call',params:{name:tool,arguments:JSON.parse(argument)}});
  console.log(JSON.stringify(response));
  if (response.error || response.result?.isError) process.exitCode=1;
} catch (error) { console.error(error.message);process.exitCode=1; }
finally { if(session) await request('DELETE').catch(()=>{}); }
