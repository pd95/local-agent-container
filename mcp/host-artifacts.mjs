#!/usr/bin/env node
import fs from 'node:fs/promises';
import {constants} from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import readline from 'node:readline';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import {authorizeSource, inside} from './artifact-policy.mjs';

const protocols = new Set(['2024-11-05','2025-03-26','2025-06-18']);
const optionalDestination={destinationName:{type:'string'},overwrite:{type:'boolean',default:false}};
const extraction={...optionalDestination,filter:{type:'string'},testId:{type:'string'},onlyFailures:{type:'boolean',default:false}};
const schema = (properties, required) => ({type:'object',properties,required,additionalProperties:false});
export const tools = [
  {name:'import_artifact',description:'Import an approved host file or directory into this container’s /workdir/.host-artifacts. Use for host files such as images, logs, reports, documents, or directories.',inputSchema:schema({sourcePath:{type:'string'},...optionalDestination},['sourcePath'])},
  {name:'extract_xcode_test_attachments',description:'Export retained Xcode test attachments from an approved .xcresult bundle. Optional filename glob, test identifier, and failures-only selection. Returns local paths to attachments and metadata.',inputSchema:schema({sourcePath:{type:'string'},...extraction},['sourcePath'])},
  {name:'host_artifacts_status',description:'List this container’s effective host artifact source grants and destination. Does not modify permissions or invoke Xcode.',inputSchema:schema({},[])}
];
export function availableTools(config) {
  return tools.filter(tool => tool.name !== 'extract_xcode_test_attachments' || config.xcode_enabled === true);
}
function validateArguments(config, name, args) {
  const tool=availableTools(config).find(item => item.name === name);
  if (!tool) throw new Error('Unknown host-artifacts tool');
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('Tool arguments must be an object');
  for (const [key,value] of Object.entries(args)) {
    const property=tool.inputSchema.properties[key];
    if (!property || typeof value !== property.type || (typeof value === 'string' && (!value || /[\x00-\x1f\x7f]/.test(value)))) throw new Error(`Invalid argument: ${key}`);
  }
  for (const key of tool.inputSchema.required) if (!Object.hasOwn(args,key)) throw new Error(`Missing argument: ${key}`);
}
function destinationName(value) {
  if (typeof value !== 'string' || !value || path.isAbsolute(value) || /[\\\x00-\x1f\x7f]/.test(value) || value.split('/').some(part => !part || part === '.' || part === '..')) throw new Error('destinationName must be a relative child path');
  return value;
}
function fitFilename(stem,extension,suffix='') {
  const characters=Array.from(stem);
  while (Buffer.byteLength(`${characters.join('')}${suffix}${extension}`) > 255 && characters.length) characters.pop();
  const name=`${characters.join('')}${suffix}${extension}`;
  if (Buffer.byteLength(name) > 255) throw new Error('Artifact filename is too long; provide a shorter destinationName');
  return name;
}
function uniqueName(source,extension=path.extname(source)) {
  return fitFilename(path.basename(source,extension),extension,`-${randomUUID()}`);
}
export function startProcess(command, args, signal, env = process.env, limit = 8 * 1024 * 1024) {
  signal?.throwIfAborted();
  const child=spawn(command,args,{env,stdio:['pipe','pipe','pipe']});
  const stdout=[], stderr=[];
  let size=0, escalation;
  const abort = () => { child.stdin.destroy(); child.kill('SIGTERM'); escalation=setTimeout(()=>child.kill('SIGKILL'),1000); escalation.unref(); };
  signal?.addEventListener('abort',abort,{once:true});
  const result=new Promise((resolve,reject) => {
    let failure;
    const record=(chunk,stream) => {
      size+=chunk.length;
      if (size > limit) { failure=new Error('Host artifact subprocess output exceeded its limit'); abort(); return; }
      (stream === 'stdout' ? stdout : stderr).push(chunk);
    };
    child.stdout.on('data',chunk=>record(chunk,'stdout'));
    child.stderr.on('data',chunk=>record(chunk,'stderr'));
    child.stdin.on('error',error=>{ if (error.code !== 'EPIPE') failure=error; });
    child.once('error',error=>{ failure=error; });
    child.once('close',(code) => {
      clearTimeout(escalation); signal?.removeEventListener('abort',abort);
      if (signal?.aborted) reject(new Error('Host artifact operation cancelled'));
      else if (failure) reject(failure);
      else if (code !== 0) reject(new Error(`Host artifact subprocess failed: ${Buffer.concat(stderr).toString().trim().slice(0,2000) || `exit ${code}`}`));
      else resolve(Buffer.concat(stdout).toString());
    });
  });
  // Consumers may still be streaming stdin when a subprocess exits.
  result.catch(()=>{});
  return {child,result};
}
async function run(command,args,signal,env) {
  const {child,result}=startProcess(command,args,signal,env);
  child.stdin.end();
  return result;
}
export async function* sourceFrames(source, root, signal, ancestors = new Set(), relative = '', forbiddenDirectory, expectedKind) {
  signal?.throwIfAborted();
  const helper=fileURLToPath(new URL('./host-artifacts-reader.py',import.meta.url));
  const child=spawn('python3',['-I',helper,JSON.stringify({source,root,relative,forbiddenDirectory,expectedKind})],{stdio:['ignore','pipe','pipe']});
  let diagnostic='', failure, escalation;
  const abort=()=>{ child.kill('SIGTERM'); escalation=setTimeout(()=>child.kill('SIGKILL'),1000); escalation.unref(); };
  signal?.addEventListener('abort',abort,{once:true});
  child.stderr.on('data',chunk=>{ diagnostic=(diagnostic+chunk.toString()).slice(-65536); });
  child.once('error',error=>{ failure=error; });
  const done=new Promise((resolve,reject)=>child.once('close',code=>{
    clearTimeout(escalation);
    if (signal?.aborted) reject(new Error('Host artifact operation cancelled'));
    else if (failure) reject(new Error(`Safe host artifact reads require host Python 3: ${failure.message}`));
    else if (code !== 0) reject(new Error(diagnostic.trim() || 'Safe host artifact read failed'));
    else resolve();
  }));
  done.catch(()=>{});
  try {
    // Readline queues lines independently of its consumer. Reading stdout
    // directly instead keeps the pipe backpressured while a frame is yielded.
    let pending=Buffer.alloc(0);
    for await (const chunk of child.stdout) {
      pending=Buffer.concat([pending,chunk]);
      let newline;
      while ((newline=pending.indexOf(10)) !== -1) {
        signal?.throwIfAborted();
        if (newline > 100000) throw new Error('Artifact source frame is too large');
        const line=pending.subarray(0,newline).toString();
        pending=pending.subarray(newline+1);
        yield JSON.parse(line);
      }
      if (pending.length > 100000) throw new Error('Artifact source frame is too large');
    }
    if (pending.length) throw new Error('Incomplete artifact source frame');
    await done;
  } finally {
    signal?.removeEventListener('abort',abort);
    if (child.exitCode === null && child.signalCode === null) abort();
    await done.catch(()=>{});
  }
}
export async function inspectWorkspace(config,signal) {
  // Match agentctl's running-state check rather than assuming inspect's status
  // field exists or has a particular representation across CLI versions.
  const running=await run(config.container_command,['ls','--quiet'],signal);
  if (!running.split(/\r?\n/).some(name=>name.trim() === config.container)) throw new Error('The owning container is not running');
  const inspected=JSON.parse(await run(config.container_command,['inspect',config.container],signal));
  const entry=Array.isArray(inspected) ? inspected[0] : inspected;
  if (!entry || typeof entry !== 'object') throw new Error('Invalid owning container inspection');
  const configuration=entry.configuration ?? entry;
  const mount=configuration.mounts?.find(item=>(item.destination ?? item.dst ?? item.target) === '/workdir');
  const source=mount?.source ?? mount?.src;
  if (typeof source !== 'string') throw new Error('The owning container has no host-backed /workdir mount');
  const options=Array.isArray(mount.options) ? mount.options : String(mount.options || '').split(',');
  if (options.some(option=>['ro','readonly'].includes(option))) throw new Error('The owning container workdir is read-only');
  if (!path.isAbsolute(source)) throw new Error('Invalid host workdir mount');
  return {hostWorkdir:await fs.realpath(source)};
}
async function transfer(config,source,root,kind,destination,overwrite,signal,progress) {
  const workspace=await inspectWorkspace(config,signal);
  destinationName(destination);
  const forbiddenDirectory=path.join(workspace.hostWorkdir,'.host-artifacts');
  if (kind === 'directory' && inside(forbiddenDirectory,source)) throw new Error('Cannot import a directory containing the artifact destination');
  signal?.throwIfAborted();
  const operation=new AbortController();
  const abort=()=>operation.abort();
  signal?.addEventListener('abort',abort,{once:true});
  const {child,result}=startProcess(config.container_command,['exec','-i','-u','coder',config.container,'node','/usr/local/lib/agentctl/host-artifacts-writer.mjs'],operation.signal);
  let count=0, lastProgress=0;
  const send=async message => {
    operation.signal.throwIfAborted();
    if (!child.stdin.write(`${JSON.stringify(message)}\n`)) await Promise.race([once(child.stdin,'drain'),result.then(()=>{ throw new Error('Guest writer exited during transfer'); })]);
    if (message.op === 'data') count+=Buffer.byteLength(message.data,'base64');
    if (Date.now()-lastProgress > 1000) { progress?.(count); lastProgress=Date.now(); }
  };
  try {
    await send({op:'start',kind,destination,overwrite});
    for await (const frame of sourceFrames(source,root,operation.signal,new Set(),'',forbiddenDirectory,kind)) await send(frame);
    await send({op:'finish'}); child.stdin.end();
    const response=JSON.parse(await result);
    return {...response,hostPath:path.join(workspace.hostWorkdir,'.host-artifacts',destination)};
  } catch (error) { operation.abort(); await result.catch(()=>{}); throw error; }
  finally { signal?.removeEventListener('abort',abort); }
}
function readableFilename(value) {
  if (typeof value !== 'string' || !value || /[\x00-\x1f\x7f]/.test(value)) throw new Error('Invalid attachment name in export manifest');
  const name=value.replace(/[\\/:*?"<>|]/g,'-');
  if (name === '.' || name === '..') throw new Error('Invalid attachment name in export manifest');
  return name;
}
export async function prepareAttachments(exportRoot,outputRoot,manifest,sourcePath) {
  if (!Array.isArray(manifest)) throw new Error('Invalid Xcode export manifest');
  await fs.mkdir(path.join(outputRoot,'attachments'),{recursive:true,mode:0o700});
  const files=[];
  const names=new Set();
  for (const test of manifest) {
    if (!test || typeof test.testIdentifier !== 'string' || !Array.isArray(test.attachments)) throw new Error('Invalid test in Xcode export manifest');
    for (const attachment of test.attachments) {
      if (!attachment || typeof attachment.isAssociatedWithFailure !== 'boolean') throw new Error('Invalid attachment in Xcode export manifest');
      const exportedFileName=destinationName(attachment.exportedFileName);
      const input=path.join(exportRoot,exportedFileName);
      const real=await fs.realpath(input);
      if (!inside(real,exportRoot) || (await fs.lstat(input)).isSymbolicLink()) throw new Error('Export manifest points outside its staging directory');
      const stats=await fs.stat(real);
      if (!stats.isFile()) throw new Error('Exported attachment is not a regular file');
      const originalName=readableFilename(attachment.suggestedHumanReadableName);
      const extension=path.extname(originalName), stem=path.basename(originalName,extension);
      let filename=fitFilename(stem,extension), index=2;
      while (names.has(filename.normalize('NFC').toLowerCase())) filename=fitFilename(stem,extension,` (${index++})`);
      names.add(filename.normalize('NFC').toLowerCase());
      await fs.copyFile(real,path.join(outputRoot,'attachments',filename),constants.COPYFILE_EXCL);
      files.push({...attachment,testIdentifier:test.testIdentifier,...(test.testIdentifierURL ? {testIdentifierURL:test.testIdentifierURL} : {}),filename,size:stats.size});
    }
  }
  await fs.writeFile(path.join(outputRoot,'manifest.json'),`${JSON.stringify(manifest,null,2)}\n`,{mode:0o600});
  const metadata={sourcePath,attachments:files};
  await fs.writeFile(path.join(outputRoot,'metadata.json'),`${JSON.stringify(metadata,null,2)}\n`,{mode:0o600});
  return metadata;
}
export async function callTool(config,name,args,signal,progress) {
  validateArguments(config,name,args);
  if (name === 'host_artifacts_status') return {container:config.container,destination:'/workdir/.host-artifacts',...config.policy};
  const source=await authorizeSource(args.sourcePath,config.policy,name === 'extract_xcode_test_attachments' ? 'directory' : undefined);
  if (name === 'import_artifact') {
    const destination=args.destinationName || uniqueName(source.sourcePath);
    const imported=await transfer(config,source.sourcePath,source.root,source.kind,destination,args.overwrite ?? false,signal,progress);
    return {...imported,sourcePath:source.sourcePath,modifiedAt:source.stats.mtime.toISOString()};
  }
  if (!source.sourcePath.endsWith('.xcresult')) throw new Error('Source must be an .xcresult bundle');
  await inspectWorkspace(config,signal);
  const stage=await fs.mkdtemp(path.join(await fs.realpath(os.tmpdir()),'agentctl-artifacts-'));
  try {
    // Materialize an authorized snapshot before invoking Xcode: the tool must
    // never follow bundle symlinks into unauthorized host sources.
    const bundle=path.join(stage,'source.xcresult');
    await snapshotDirectory(source.sourcePath,source.root,bundle,signal);
    const exportRoot=path.join(stage,'export');
    const outputRoot=path.join(stage,'output');
    await fs.mkdir(exportRoot,{mode:0o700});
    await fs.mkdir(outputRoot,{mode:0o700});
    const command=['xcresulttool','export','attachments','--path',bundle,'--output-path',exportRoot];
    if (args.filter) command.push('--filter',args.filter);
    if (args.testId) command.push('--test-id',args.testId);
    if (args.onlyFailures) command.push('--only-failures');
    try { await run(config.xcrun_command || '/usr/bin/xcrun',command,signal,config.developer_dir ? {...process.env,DEVELOPER_DIR:config.developer_dir} : process.env); }
    catch (error) {
      if (signal?.aborted) throw error;
      throw new Error(`Xcode attachment export failed: ${error.message}. For unsupported commands or options, check xcrun xcresulttool help export attachments in the selected Xcode.`);
    }
    const manifestPath=path.join(exportRoot,'manifest.json');
    if ((await fs.lstat(manifestPath)).isSymbolicLink() || (await fs.stat(manifestPath)).size > 16 * 1024 * 1024) throw new Error('Invalid or oversized Xcode export manifest');
    const manifest=JSON.parse(await fs.readFile(manifestPath,'utf8'));
    const metadata=await prepareAttachments(exportRoot,outputRoot,manifest,source.sourcePath);
    const destination=`test-results/${args.destinationName || uniqueName(path.basename(source.sourcePath,'.xcresult'),'')}`;
    const workspacePath=path.posix.join('/workdir/.host-artifacts',destination);
    metadata.destinationPath=workspacePath;
    for (const attachment of metadata.attachments) attachment.workspacePath=path.posix.join(workspacePath,'attachments',attachment.filename);
    await fs.writeFile(path.join(outputRoot,'metadata.json'),`${JSON.stringify(metadata,null,2)}\n`,{mode:0o600});
    const imported=await transfer(config,outputRoot,outputRoot,'directory',destination,args.overwrite ?? false,signal,progress);
    return {...imported,sourcePath:source.sourcePath,extractedCount:metadata.attachments.length,metadataPath:path.posix.join(workspacePath,'metadata.json'),manifestPath:path.posix.join(workspacePath,'manifest.json'),attachmentsPath:path.posix.join(workspacePath,'attachments')};
  } finally { await fs.rm(stage,{recursive:true,force:true}); }
}
async function snapshotDirectory(source,root,destination,signal) {
  await fs.mkdir(destination,{mode:0o700});
  let file;
  try {
    for await (const frame of sourceFrames(source,root,signal,new Set(),'',undefined,'directory')) {
      if (frame.op === 'directory') await fs.mkdir(path.join(destination,frame.path),{mode:0o700});
      else if (frame.op === 'file') file=await fs.open(path.join(destination,frame.path),'wx',0o600);
      else if (frame.op === 'data') await file.writeFile(Buffer.from(frame.data,'base64'));
      else if (frame.op === 'end-file') { await file.close(); file=null; }
    }
  } finally { if (file) await file.close(); }
}
export async function serve(config,input=process.stdin,output=process.stdout) {
  const active=new Map();
  const send=message=>output.write(`${JSON.stringify(message)}\n`);
  const lines=readline.createInterface({input,crlfDelay:Infinity});
  const stop=()=>{ for (const item of active.values()) item.controller.abort(); lines.close(); };
  if (input === process.stdin) { process.once('SIGTERM',stop); process.once('SIGINT',stop); }
  try {
    for await (const line of lines) {
      let request;
      try { if (line.length > 8 * 1024 * 1024) throw new Error(); request=JSON.parse(line); }
      catch { send({jsonrpc:'2.0',id:null,error:{code:-32700,message:'Invalid JSON'}}); continue; }
      if (!request || typeof request !== 'object' || Array.isArray(request) || request.jsonrpc !== '2.0' || typeof request.method !== 'string') { send({jsonrpc:'2.0',id:null,error:{code:-32600,message:'Invalid request'}}); continue; }
      if (request.method === 'notifications/cancelled') { active.get(request.params?.requestId)?.controller.abort(); continue; }
      if (!Object.hasOwn(request,'id')) continue;
      if (request.method === 'initialize') {
        const protocol=request.params?.protocolVersion;
        send({jsonrpc:'2.0',id:request.id,result:{protocolVersion:protocols.has(protocol) ? protocol : '2025-03-26',capabilities:{tools:{}},serverInfo:{name:'host-artifacts',version:'1'}}});
      } else if (request.method === 'ping') send({jsonrpc:'2.0',id:request.id,result:{}});
      else if (request.method === 'tools/list') send({jsonrpc:'2.0',id:request.id,result:{tools:availableTools(config)}});
      else if (request.method === 'tools/call') {
        const controller=new AbortController();
        const token=request.params?._meta?.progressToken;
        const progress=count=>{ if (token !== undefined) send({jsonrpc:'2.0',method:'notifications/progress',params:{progressToken:token,progress:count}}); };
        const promise=callTool(config,request.params?.name,request.params?.arguments || {},controller.signal,progress)
          .then(value=>send({jsonrpc:'2.0',id:request.id,result:{content:[{type:'text',text:JSON.stringify(value)}],structuredContent:value}}))
          .catch(error=>send({jsonrpc:'2.0',id:request.id,result:{isError:true,content:[{type:'text',text:error.message}]}}))
          .finally(()=>active.delete(request.id));
        active.set(request.id,{controller,promise});
      } else send({jsonrpc:'2.0',id:request.id,error:{code:-32601,message:'Method not found'}});
    }
  } finally {
    stop(); await Promise.allSettled([...active.values()].map(item=>item.promise));
    if (input === process.stdin) { process.removeListener('SIGTERM',stop); process.removeListener('SIGINT',stop); }
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const config=JSON.parse(process.env.AGENTCTL_HOST_ARTIFACTS_CONFIG || '{}');
    if (!config.container || !path.isAbsolute(config.container_command || '') || !config.policy) throw new Error('Missing trusted host-artifacts configuration');
    await serve(config);
  } catch (error) { console.error(error.message); process.exitCode=1; }
}
