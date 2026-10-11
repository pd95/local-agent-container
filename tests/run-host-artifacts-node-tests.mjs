#!/usr/bin/env node
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {Readable, PassThrough} from 'node:stream';
import {fileURLToPath} from 'node:url';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import http from 'node:http';
import {normalizeDefinition, normalizeGrant, effectivePolicy, authorizeSource, mutatePolicy, isXcodePreset} from '../mcp/artifact-policy.mjs';
import {writeArtifacts} from '../mcp/host-artifacts-writer.mjs';
import {callTool, availableTools, prepareAttachments, sourceFrames, inspectWorkspace} from '../mcp/host-artifacts.mjs';

const root=path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const guestTest=(name,fn)=>test(name,{skip:process.platform !== 'linux' ? 'Linux guest writer; verified inside containers by macOS integration tests' : false},fn);
async function fixture(t) {
  const directory=await fs.mkdtemp(path.join(await fs.realpath(os.tmpdir()),'agentctl-artifact-test-'));
  t.after(()=>fs.rm(directory,{recursive:true,force:true}));
  const source=path.join(directory,'source'), workdir=path.join(directory,'workdir');
  await fs.mkdir(source); await fs.mkdir(workdir);
  return {directory,source,workdir};
}
async function policyFor(source,kind='directory') {
  const definition=await normalizeDefinition({name:'host-artifacts',type:'builtin',grants:[{kind,value:source}]});
  return {definition,policy:await effectivePolicy([definition],os.homedir())};
}
async function write(workdir,frames) {
  let output='';
  const result=await writeArtifacts(workdir,Readable.from(frames.map(frame=>`${JSON.stringify(frame)}\n`)),{write:chunk=>{output+=chunk;}});
  assert.deepEqual(JSON.parse(output),result);
  return result;
}
function fileFrames(destination,content='hello',overwrite=false) {
  return [{op:'start',kind:'file',destination,overwrite},{op:'file',path:'',size:Buffer.byteLength(content)},{op:'data',data:Buffer.from(content).toString('base64')},{op:'end-file'},{op:'finish'}];
}
async function commands(t,f) {
  const container=path.join(f.directory,'container.mjs');
  const xcrun=path.join(f.directory,'xcrun.mjs');
  const log=path.join(f.directory,'invocations');
  await fs.writeFile(container,`#!/usr/bin/env node
import fs from 'node:fs';
import {writeArtifacts} from ${JSON.stringify(new URL('../mcp/host-artifacts-writer.mjs',import.meta.url).href)};
const args=process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(args)+'\\n');
if(args[0]==='ls') console.log(process.env.ARTIFACT_TEST_STATUS==='stopped'?'':'own-container');
else if(args[0]==='inspect') {
 const item={status:{state:process.env.ARTIFACT_TEST_STATUS||'running'},configuration:{mounts:[{source:${JSON.stringify(f.workdir)},destination:'/workdir',options:process.env.ARTIFACT_TEST_RO==='1'?['readonly']:[]}]}};
 if(process.env.ARTIFACT_TEST_INSPECT_STATUS_ABSENT==='1') delete item.status;
 console.log(JSON.stringify(process.env.ARTIFACT_TEST_INSPECT_OBJECT==='1'?item:[item]));
}
else {
 if(JSON.stringify(args.slice(0,4))!==JSON.stringify(['exec','-i','-u','coder']) || args[4]!=='own-container') {console.error('Wrong container or missing interactive flag');process.exit(1);}
 try {await writeArtifacts(${JSON.stringify(f.workdir)},process.stdin,process.stdout);} catch(error){console.error(error.message);process.exitCode=1;}
}
`,{mode:0o700});
  await fs.writeFile(xcrun,`#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
const args=process.argv.slice(2);
await fs.appendFile(${JSON.stringify(log)},JSON.stringify(args)+'\\n');
if(process.env.ARTIFACT_TEST_EXPORT_FAIL==='1') {console.error('Unsupported command');process.exit(1);}
if(process.env.ARTIFACT_TEST_EXPORT_HANG==='1') {setInterval(()=>{},1000);await new Promise(()=>{});}
const destination=args[args.indexOf('--output-path')+1];
let manifest=JSON.parse(await fs.readFile(${JSON.stringify(path.join(f.directory,'export-input.json'))},'utf8'));
if(args.includes('--test-id')) manifest=manifest.filter(test=>test.testIdentifier===args[args.indexOf('--test-id')+1]);
for(const test of manifest){
 if(args.includes('--only-failures')) test.attachments=test.attachments.filter(item=>item.isAssociatedWithFailure);
 if(args.includes('--filter')) test.attachments=test.attachments.filter(item=>item.exportedFileName.endsWith('.png'));
 for(const attachment of test.attachments) await fs.writeFile(path.join(destination,attachment.exportedFileName),'attachment');
}
await fs.writeFile(path.join(destination,'manifest.json'),JSON.stringify(manifest));
console.log('Exported attachments');
`,{mode:0o700});
  for (const name of ['ARTIFACT_TEST_STATUS','ARTIFACT_TEST_RO','ARTIFACT_TEST_EXPORT_FAIL','ARTIFACT_TEST_EXPORT_HANG','ARTIFACT_TEST_INSPECT_OBJECT','ARTIFACT_TEST_INSPECT_STATUS_ABSENT']) {
    const previous=process.env[name];
    t.after(()=>{ if(previous===undefined) delete process.env[name];else process.env[name]=previous; });
  }
  return {container,xcrun,log};
}
function sampleManifest() {
  const attachment=(file,name,failure=false)=>({exportedFileName:file,suggestedHumanReadableName:name,isAssociatedWithFailure:failure,configurationName:'Test configuration',deviceName:'Test device',deviceId:'fixture-device',timestamp:1700000000});
  return [
    {testIdentifier:'Tests/testOne()',testIdentifierURL:'test://fixture/testOne',attachments:[attachment('one.png','Screenshot_0_fixture.png'),attachment('two.png','Screenshot_0_fixture.png',true),attachment('log.txt','Console.txt')]},
    {testIdentifier:'Tests/testTwo()',attachments:[{...attachment('three.png','Screenshot_0_fixture.png'),repetitionNumber:2}]}
  ];
}

test('grants validate syntax, source type and immutable builtin definition',async t=>{
  const f=await fixture(t), file=path.join(f.source,'file.txt'); await fs.writeFile(file,'text');
  await assert.rejects(normalizeGrant({kind:'directory',value:file}),/directory/);
  await assert.rejects(normalizeGrant({kind:'file',value:f.source}),/file/);
  await assert.rejects(normalizeGrant({kind:'file-pattern',value:'['}),/regular expression/);
  await assert.rejects(normalizeDefinition({name:'host-artifacts',type:'builtin',command:'/bin/sh'}),/Invalid/);
  const definition=await normalizeDefinition({name:'host-artifacts',type:'builtin'});
  const policy=await effectivePolicy([definition],os.homedir());
  await assert.rejects(authorizeSource(file,policy),/not authorized/);
  const grant=await normalizeGrant({kind:'file',value:file});
  assert.equal((await authorizeSource(file,{grants:[grant]})).kind,'file');
  await fs.rm(file);
  const next=await mutatePolicy([{...definition,grants:[grant]}],'revoke',grant.id,os.homedir());
  assert.deepEqual(next[0].grants,[]);
});

test('typed patterns match full resolved paths and directory descendants',async t=>{
  const f=await fixture(t), bundle=path.join(f.source,'Test-a.xcresult'); await fs.mkdir(bundle);
  const file=path.join(bundle,'image.png'); await fs.writeFile(file,'png');
  const escaped=f.source.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  const directory=await normalizeGrant({kind:'directory-pattern',value:`${escaped}/Test-[^/]+\\.xcresult`});
  assert.equal((await authorizeSource(file,{grants:[directory]})).root,bundle);
  await assert.rejects(authorizeSource(bundle,{grants:[{kind:'file-pattern',value:'.*'}]}),/not authorized/);
  await assert.rejects(authorizeSource(file,{grants:[{kind:'file-pattern',value:'image\\.png'}]}),/not authorized/);
  await assert.rejects(authorizeSource(file,{grants:[{kind:'directory',value:`${bundle}other`}]}),/not authorized/);
  const alias=path.join(f.source,'alias');await fs.symlink(file,alias);
  await assert.rejects(authorizeSource(alias,{grants:[{kind:'file',value:alias}]}),/not authorized/);
});

test('workspace inspection accepts object or array output without assuming inspect status',async t=>{
  const f=await fixture(t), command=await commands(t,f);
  const config={container:'own-container',container_command:command.container};
  assert.equal((await inspectWorkspace(config)).hostWorkdir,f.workdir);
  process.env.ARTIFACT_TEST_INSPECT_OBJECT='1';
  assert.equal((await inspectWorkspace(config)).hostWorkdir,f.workdir);
  process.env.ARTIFACT_TEST_INSPECT_STATUS_ABSENT='1';
  assert.equal((await inspectWorkspace(config)).hostWorkdir,f.workdir);
  await assert.rejects(inspectWorkspace({...config,container:'other-container'}),/not running/);
  process.env.ARTIFACT_TEST_STATUS='stopped';
  await assert.rejects(inspectWorkspace(config),/not running/);
});

test('Xcode permissions derive in either order and preserve explicit presets after removal',async ()=>{
  const definition=await normalizeDefinition({name:'host-artifacts',type:'builtin'});
  const xcode={name:'xcode',command:'/usr/bin/xcrun',args:['mcpbridge'],shared_process:true};
  assert.equal(isXcodePreset({name:'xcode',command:'/bin/other',shared_process:true}),false);
  for (const definitions of [[definition,xcode],[xcode,definition]]) assert.equal((await effectivePolicy(definitions,'/Users/test')).presets[0].origin,'automatic');
  assert.deepEqual((await effectivePolicy([definition],'/Users/test')).grants,[]);
  const explicit=await mutatePolicy([definition,xcode],'allow-preset','xcode','/Users/test');
  const policy=await effectivePolicy(explicit.filter(item=>item.name!=='xcode'),'/Users/test');
  assert.equal(policy.presets[0].origin,'explicit');
  assert.deepEqual(policy.grants.map(grant=>grant.id),['xcode-1','xcode-2','xcode-3','xcode-4']);
  assert.ok(policy.grants.every(item=>item.preset==='xcode'));
  const repeated=await mutatePolicy(explicit,'allow-preset','xcode','/Users/test');
  assert.deepEqual(repeated,explicit);
  await assert.rejects(normalizeDefinition({name:'host-artifacts',type:'builtin',presets:['papageye']}));
  const retired=await effectivePolicy([{...definition,presets:['papageye']}],'/Users/test');
  assert.deepEqual(retired.grants,[]);
  await assert.rejects(mutatePolicy([definition,xcode],'revoke','automatic:xcode','/Users/test'),/automatic/);
});

test('Xcode preview grants accept display-name PNGs while retaining directory and type boundaries',async ()=>{
  const definition=await normalizeDefinition({name:'host-artifacts',type:'builtin'});
  const xcode={name:'xcode',command:'/usr/bin/xcrun',args:['mcpbridge'],shared_process:true};
  for (const definitions of [[definition,xcode],[{...definition,presets:['xcode']}]]) {
    const policy=await effectivePolicy(definitions,'/Users/test');
    const preview=new RegExp(policy.grants.find(grant=>grant.id==='xcode-1').value);
    for (const prefix of ['/var/folders','/private/var/folders']) {
      const directory=`${prefix}/v1/wdvlbd5j7sj4kpz6c4d4k3680000gn/T/ActionArtifacts/default/RenderPreview`;
      for (const name of ['Settings - 2026-10-11 at 18.46.11.png','RenderPreview.png','Einstellungen Übersicht.png']) assert.equal(preview.test(`${directory}/${name}`),true);
      for (const name of ['nested/Settings.png','Settings.txt','Settings.jpeg','.png','Settings.png/extra']) assert.equal(preview.test(`${directory}/${name}`),false);
      assert.equal(preview.test(`${directory}Other/Settings.png`),false);
    }
  }
});

test('Xcode result grants include tool-returned ActionArtifacts bundles with narrow directory boundaries',async ()=>{
  const definition=await normalizeDefinition({name:'host-artifacts',type:'builtin'});
  const xcode={name:'xcode',command:'/usr/bin/xcrun',args:['mcpbridge'],shared_process:true};
  for (const definitions of [[definition,xcode],[{...definition,presets:['xcode']}]]) {
    const grants=(await effectivePolicy(definitions,'/Users/test')).grants.filter(grant=>grant.kind==='directory-pattern').map(grant=>new RegExp(grant.value));
    const approved=name=>grants.some(rule=>rule.test(name));
    assert.equal(approved('/Users/test/Library/Developer/Xcode/DerivedData/App-hash/Logs/Test/Test-App.xcresult'),false);
    for (const prefix of ['/var/folders','/private/var/folders']) {
      const parent=`${prefix}/v1/fixture/T/ActionArtifacts/default`;
      for (const tool of ['RunAllTests','RunSomeTests']) assert.equal(approved(`${parent}/${tool}/Test-App - today.xcresult`),true);
      for (const invalid of ['RenderPreview/Test-App.xcresult','RunSomeTests/nested/Test-App.xcresult','RunSomeTests/App.xcresult','RunSomeTests/Test-App.txt','RunSomeTests/Test-App.xcresult/Diagnostics']) assert.equal(approved(`${parent}/${invalid}`),false);
    }
  }
});

test('source traversal resolves internal links and rejects escapes, cycles and special files',async t=>{
  const f=await fixture(t);await fs.writeFile(path.join(f.source,'file'),'bytes');
  await fs.symlink('file',path.join(f.source,'link'));
  const collect=async ()=>{const frames=[];for await(const frame of sourceFrames(f.source,f.source))frames.push(frame);return frames;};
  assert.equal((await collect()).filter(frame=>frame.op==='file').length,2);
  await fs.symlink(f.directory,path.join(f.source,'escape'));
  await assert.rejects(collect(),/escapes/);await fs.rm(path.join(f.source,'escape'));
  await fs.symlink('.',path.join(f.source,'cycle'));
  await assert.rejects(collect(),/cycle/);
});

test('host reader rejects ancestor replacement and keeps recursive reads on pinned directories',async t=>{
  const f=await fixture(t);
  await fs.writeFile(path.join(f.source,'file'),'APPROVED');
  const secret=path.join(f.directory,'secret'); await fs.mkdir(secret);
  await fs.writeFile(path.join(secret,'file'),'HOST SECRET');
  const helper=path.join(root,'mcp/host-artifacts-reader.py');
  const harness=`
import importlib.util, json, os, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('reader', sys.argv[1])
reader = importlib.util.module_from_spec(spec); spec.loader.exec_module(reader)
source, secret, scenario = sys.argv[2:]
if scenario == 'before-open':
    original = os.open
    def race(name, flags, *args, **kwargs):
        if name == os.path.basename(source):
            os.rename(source, source + '-original'); os.symlink(secret, source)
        return original(name, flags, *args, **kwargs)
    os.open = race
    try:
        reader.main({'source': source + '/file', 'root': source})
    except OSError:
        print('REJECTED')
    else:
        raise AssertionError('Ancestor substitution was accepted')
else:
    original = os.listdir
    def race(descriptor):
        os.rename(source, source + '-original'); os.symlink(secret, source)
        return original(descriptor)
    os.listdir = race
    reader.main({'source': source, 'root': source})
`;
  const script=path.join(f.directory,'race.py'); await fs.writeFile(script,harness);
  const run=promisify(execFile);
  const rejected=await run('python3',['-I',script,helper,f.source,secret,'before-open']);
  assert.equal(rejected.stdout.trim(),'REJECTED');
  await fs.unlink(f.source); await fs.rename(`${f.source}-original`,f.source);
  const pinned=await run('python3',['-I',script,helper,f.source,secret,'after-open']);
  const content=pinned.stdout.trim().split('\n').map(JSON.parse).filter(frame=>frame.op==='data').map(frame=>Buffer.from(frame.data,'base64').toString()).join('');
  assert.equal(content,'APPROVED');
});

guestTest('guest writer publishes files, directories and explicit replacements',async t=>{
  const f=await fixture(t);
  await write(f.workdir,fileFrames('nested/file.txt'));
  const target=path.join(f.workdir,'.host-artifacts/nested/file.txt');
  assert.equal(await fs.readFile(target,'utf8'),'hello');
  await assert.rejects(write(f.workdir,fileFrames('nested/file.txt')),/already exists/);
  await write(f.workdir,fileFrames('nested/file.txt','replacement',true));
  assert.equal(await fs.readFile(target,'utf8'),'replacement');
  await assert.rejects(write(f.workdir,fileFrames('nested/file.txt','partial',true).slice(0,-1)),/before finish/);
  assert.equal(await fs.readFile(target,'utf8'),'replacement');
  await write(f.workdir,[{op:'start',kind:'directory',destination:'bundle',overwrite:false},{op:'directory',path:'empty'},...fileFrames('ignored','data').slice(1,-1).map(frame=>frame.op==='file'?{...frame,path:'file'}:frame),{op:'finish'}]);
  assert.equal(await fs.readFile(path.join(f.workdir,'.host-artifacts/bundle/file'),'utf8'),'data');
  assert.ok((await fs.stat(path.join(f.workdir,'.host-artifacts/bundle/empty'))).isDirectory());
});

guestTest('guest writer refuses traversal, destination symlinks and incomplete streams',async t=>{
  const f=await fixture(t);
  await assert.rejects(write(f.workdir,fileFrames('../outside')),/destination/);
  await fs.mkdir(path.join(f.workdir,'.host-artifacts'));
  await fs.symlink(f.source,path.join(f.workdir,'.host-artifacts/escape'));
  await assert.rejects(write(f.workdir,fileFrames('escape/file')),/symlink/);
  await fs.symlink(path.join(f.source,'file'),path.join(f.workdir,'.host-artifacts/file'));
  await assert.rejects(write(f.workdir,fileFrames('file','text',true)),/symlink/);
  await assert.rejects(write(f.workdir,fileFrames('incomplete').slice(0,-1)),/before finish/);
  assert.equal((await fs.readdir(path.join(f.workdir,'.host-artifacts'))).some(name=>name.startsWith('.stage-')),false);
  assert.deepEqual(await fs.readdir(f.source),[]);
});

guestTest('guest publication rejects artifact-root and nested-parent replacement without altering victims',async t=>{
  for (const scenario of ['root','parent']) {
    for (const overwrite of [false,true]) {
      const f=await fixture(t), base=path.join(f.workdir,'.host-artifacts');
      const outside=path.join(f.directory,'outside'); await fs.mkdir(outside);
      await fs.writeFile(path.join(outside,'victim'),'original');
      let finish;
      const stream=new PassThrough();
      const writing=writeArtifacts(f.workdir,stream,{write:()=>{finish=true;}});
      writing.catch(()=>{});
      const destination=scenario === 'root' ? 'victim' : 'nested/victim';
      for (const frame of fileFrames(destination,'replacement',overwrite).slice(0,-1)) stream.write(`${JSON.stringify(frame)}\n`);
      // Waiting for the staged bytes makes the replacement occur after anchoring.
      let staged;
      for (let attempt=0;attempt<200;attempt++) {
        const entries=await fs.readdir(base).catch(()=>[]);
        staged=entries.find(name=>name.startsWith('.stage-'));
        if (staged && await fs.readFile(path.join(base,staged,'item'),'utf8').catch(()=>null)==='replacement') break;
        await new Promise(resolve=>setTimeout(resolve,5));
      }
      assert.ok(staged,'Writer did not stage its input');
      const replaced=scenario === 'root' ? base : path.join(base,'nested');
      const moved=path.join(f.directory,'detached');
      await fs.rename(replaced,moved); await fs.symlink(outside,replaced);
      stream.end(`${JSON.stringify({op:'finish'})}\n`);
      await assert.rejects(writing,/symlink|changed directory/);
      assert.equal(finish,undefined);
      assert.equal(await fs.readFile(path.join(outside,'victim'),'utf8'),'original');
      const stageRoot=scenario === 'root' ? moved : base;
      assert.equal((await fs.readdir(stageRoot)).some(name=>name.startsWith('.stage-')),false);
    }
  }
});

guestTest('guest descriptor publication remains pinned if a parent changes after validation',async t=>{
  const f=await fixture(t), outside=path.join(f.directory,'outside'); await fs.mkdir(outside);
  await fs.writeFile(path.join(outside,'victim'),'original');
  const original=fs.link;
  let replaced=false;
  fs.link=async (source,target)=>{
    if (!replaced && target.endsWith('/victim')) {
      replaced=true;
      const parent=path.join(f.workdir,'.host-artifacts/nested');
      await fs.rename(parent,path.join(f.directory,'detached'));
      await fs.symlink(outside,parent);
    }
    return original(source,target);
  };
  try { await write(f.workdir,fileFrames('nested/victim')); }
  finally { fs.link=original; }
  assert.equal(replaced,true);
  assert.equal(await fs.readFile(path.join(outside,'victim'),'utf8'),'original');
  assert.equal(await fs.readFile(path.join(f.directory,'detached/victim'),'utf8'),'hello');
});

guestTest('overwrite publication and rollback use pinned parents after ancestor substitution',async t=>{
  for (const failPublish of [false,true]) {
    const f=await fixture(t), base=path.join(f.workdir,'.host-artifacts'), parent=path.join(base,'nested');
    await write(f.workdir,fileFrames('nested/victim','previous'));
    const outside=path.join(f.directory,'outside'), detached=path.join(f.directory,'detached');
    await fs.mkdir(outside); await fs.writeFile(path.join(outside,'victim'),'outside');
    const original=fs.rename;
    let replaced=false;
    fs.rename=async (source,target)=>{
      if (!replaced && source.endsWith('/victim')) {
        replaced=true;
        await original(parent,detached); await fs.symlink(outside,parent);
      }
      if (failPublish && source.endsWith('/item')) throw new Error('Injected publication failure');
      return original(source,target);
    };
    try {
      if (failPublish) await assert.rejects(write(f.workdir,fileFrames('nested/victim','replacement',true)),/Injected/);
      else await write(f.workdir,fileFrames('nested/victim','replacement',true));
    } finally { fs.rename=original; }
    assert.equal(replaced,true);
    assert.equal(await fs.readFile(path.join(outside,'victim'),'utf8'),'outside');
    assert.equal(await fs.readFile(path.join(detached,'victim'),'utf8'),failPublish ? 'previous' : 'replacement');
    assert.equal((await fs.readdir(base)).some(name=>name.startsWith('.stage-')),false);
  }
});

test('host reads enforce the originally authorized source type before streaming',async t=>{
  const f=await fixture(t);
  const frames=[];
  await assert.rejects(async()=>{
    for await (const frame of sourceFrames(f.source,f.source,undefined,new Set(),'',undefined,'file')) frames.push(frame);
  },/Source type changed/);
  assert.deepEqual(frames,[]);
});

test('source streaming backpressures a slow consumer without buffering the complete file',async t=>{
  const f=await fixture(t), source=path.join(f.source,'large');
  const handle=await fs.open(source,'wx'); await handle.truncate(64*1024*1024); await handle.close();
  const script=path.join(f.directory,'slow-consumer.mjs');
  await fs.writeFile(script,`
import assert from 'node:assert/strict';
import {sourceFrames} from ${JSON.stringify(new URL('../mcp/host-artifacts.mjs',import.meta.url).href)};
const frames=sourceFrames(process.argv[2],process.argv[2]);
const before=process.memoryUsage().heapUsed;
assert.equal((await frames.next()).value.op,'file');
await new Promise(resolve=>setTimeout(resolve,1200));
assert.ok(process.memoryUsage().heapUsed-before<16*1024*1024,'Source frames buffered ahead of their consumer');
await frames.return();
`);
  await promisify(execFile)(process.execPath,['--max-old-space-size=64',script,source],{timeout:10000});
});

guestTest('large directory imports and failed-transfer cleanup stay within a low descriptor limit',async t=>{
  const f=await fixture(t), script=path.join(f.directory,'many-directories.mjs');
  await fs.writeFile(script,`
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {Readable} from 'node:stream';
import {writeArtifacts} from ${JSON.stringify(new URL('../mcp/host-artifacts-writer.mjs',import.meta.url).href)};
async function* frames(complete) {
 yield JSON.stringify({op:'start',kind:'directory',destination:complete?'complete':'incomplete',overwrite:false})+'\\n';
 for(let i=0;i<200;i++) {
  for(const frame of [{op:'directory',path:'dir-'+i},{op:'file',path:'dir-'+i+'/file',size:1},{op:'data',data:'eA=='},{op:'end-file'}]) yield JSON.stringify(frame)+'\\n';
 }
 if(complete) yield JSON.stringify({op:'finish'})+'\\n';
}
await writeArtifacts(process.argv[2],Readable.from(frames(true)),{write:()=>{}});
assert.equal((await fs.readdir(process.argv[2]+'/.host-artifacts/complete')).length,200);
await assert.rejects(writeArtifacts(process.argv[2],Readable.from(frames(false)),{write:()=>{}}),/before finish/);
assert.deepEqual(await fs.readdir(process.argv[2]+'/.host-artifacts'),['complete']);
`);
  await promisify(execFile)('bash',['-c','ulimit -n 64; exec "$@"','artifact-descriptor-test',process.execPath,script,f.workdir],{timeout:15000});
});

guestTest('guest streaming backpressures a fast producer while destination writes are stalled',async t=>{
  const f=await fixture(t);
  let release, stalled, produced=0;
  const blocked=new Promise(resolve=>{release=resolve;});
  const started=new Promise(resolve=>{stalled=resolve;});
  const original=fs.open;
  fs.open=async (...args)=>{
    const handle=await original(...args);
    if (args[0].endsWith('/item')) {
      const write=handle.write.bind(handle);
      handle.write=async (...values)=>{ stalled(); await blocked; return write(...values); };
    }
    return handle;
  };
  const chunk=Buffer.alloc(65536).toString('base64');
  async function* produce() {
    yield JSON.stringify({op:'start',kind:'file',destination:'slow',overwrite:false})+'\n';
    yield JSON.stringify({op:'file',path:'',size:256*65536})+'\n';
    for (let index=0;index<256;index++) {
      produced++;
      yield JSON.stringify({op:'data',data:chunk})+'\n';
    }
    yield JSON.stringify({op:'end-file'})+'\n';
    yield JSON.stringify({op:'finish'})+'\n';
  }
  const writing=writeArtifacts(f.workdir,Readable.from(produce()),{write:()=>{}});
  writing.catch(()=>{});
  try {
    await started;
    await new Promise(resolve=>setTimeout(resolve,150));
    assert.ok(produced<=4,`Guest buffered ${produced} frames while its destination was stalled`);
  } finally { release(); await writing; fs.open=original; }
  assert.equal((await fs.stat(path.join(f.workdir,'.host-artifacts/slow'))).size,256*65536);
});

test('attachment names are fitted before collision detection and retain original metadata',async t=>{
  const f=await fixture(t), output=path.join(f.directory,'output');
  const names=[`${'a'.repeat(300)}.png`,`${'a'.repeat(299)}b.png`,`${'界'.repeat(100)}.png`,`${'界'.repeat(99)}語.png`];
  const manifest=[{testIdentifier:'Tests/testNames()',attachments:[]}];
  for (let index=0;index<names.length;index++) {
    await fs.writeFile(path.join(f.source,`${index}.png`),'png');
    manifest[0].attachments.push({exportedFileName:`${index}.png`,suggestedHumanReadableName:names[index],isAssociatedWithFailure:false});
  }
  const metadata=await prepareAttachments(f.source,output,manifest,'/approved/Test.xcresult');
  assert.equal(new Set(metadata.attachments.map(item=>item.filename)).size,4);
  for (const [index,item] of metadata.attachments.entries()) {
    assert.ok(Buffer.byteLength(item.filename)<=255);
    assert.ok(item.filename.endsWith('.png'));
    assert.equal(item.suggestedHumanReadableName,names[index]);
    assert.equal(await fs.readFile(path.join(output,'attachments',item.filename),'utf8'),'png');
  }
});

guestTest('import targets the owning container with interactive stdin and rejects readonly or stopped workdirs',async t=>{
  const f=await fixture(t), command=await commands(t,f), {policy}=await policyFor(f.source);
  const source=path.join(f.source,'source.txt'),content='source bytes'.repeat(12000);await fs.writeFile(source,content);
  const config={container:'own-container',container_command:command.container,policy};
  const result=await callTool(config,'import_artifact',{sourcePath:source,destinationName:'copied.txt'},new AbortController().signal);
  assert.equal(result.workspacePath,'/workdir/.host-artifacts/copied.txt');
  assert.equal(await fs.readFile(path.join(f.workdir,'.host-artifacts/copied.txt'),'utf8'),content);
  const invocations=(await fs.readFile(command.log,'utf8')).trim().split('\n').map(JSON.parse);
  assert.deepEqual(invocations.find(args=>args[0]==='exec').slice(0,5),['exec','-i','-u','coder','own-container']);
  const longSource=path.join(f.source,`${'a'.repeat(250)}.txt`);await fs.writeFile(longSource,'long name');
  const unique=await callTool(config,'import_artifact',{sourcePath:longSource});
  assert.ok(Buffer.byteLength(path.posix.basename(unique.workspacePath))<=255);
  assert.equal(await fs.readFile(unique.hostPath,'utf8'),'long name');
  await assert.rejects(callTool(config,'import_artifact',{sourcePath:source,containerName:'another'}),/argument/);
  process.env.ARTIFACT_TEST_RO='1';await assert.rejects(callTool(config,'import_artifact',{sourcePath:source}),/read-only/);
  delete process.env.ARTIFACT_TEST_RO;process.env.ARTIFACT_TEST_STATUS='stopped';
  await assert.rejects(callTool(config,'import_artifact',{sourcePath:source}),/not running/);
});

guestTest('directory imports cannot recursively copy their own artifact output',async t=>{
  const f=await fixture(t), command=await commands(t,f), {policy}=await policyFor(f.workdir);
  await fs.writeFile(path.join(f.workdir,'file.txt'),'fixture');
  await assert.rejects(callTool({container:'own-container',container_command:command.container,policy},'import_artifact',{sourcePath:f.workdir}),/containing the artifact destination/);
});

guestTest('Xcode export preserves names, metadata, repeated runs and all attachment types',async t=>{
  const f=await fixture(t), command=await commands(t,f), {policy}=await policyFor(f.source);
  const bundle=path.join(f.source,'Example.xcresult');await fs.mkdir(bundle);await fs.writeFile(path.join(bundle,'Info.plist'),'fixture');
  await fs.writeFile(path.join(f.directory,'export-input.json'),JSON.stringify(sampleManifest()));
  const config={container:'own-container',container_command:command.container,xcrun_command:command.xcrun,xcode_enabled:true,policy};
  const result=await callTool(config,'extract_xcode_test_attachments',{sourcePath:bundle,destinationName:'all'});
  assert.equal(result.extractedCount,4);
  const metadata=JSON.parse(await fs.readFile(path.join(f.workdir,'.host-artifacts/test-results/all/metadata.json'),'utf8'));
  assert.equal(metadata.attachments[0].filename,'Screenshot_0_fixture.png');
  assert.equal(metadata.attachments[1].filename,'Screenshot_0_fixture (2).png');
  assert.equal(metadata.attachments[3].filename,'Screenshot_0_fixture (3).png');
  assert.equal(metadata.attachments[3].repetitionNumber,2);
  assert.equal(metadata.attachments[0].testIdentifierURL,'test://fixture/testOne');
  assert.equal(metadata.attachments[0].workspacePath,'/workdir/.host-artifacts/test-results/all/attachments/Screenshot_0_fixture.png');
  const filtered=await callTool(config,'extract_xcode_test_attachments',{sourcePath:bundle,destinationName:'filtered',filter:'*.png',onlyFailures:true,testId:'Tests/testOne()'});
  assert.equal(filtered.extractedCount,1);
  const empty=await callTool(config,'extract_xcode_test_attachments',{sourcePath:bundle,destinationName:'empty',testId:'missing'});
  assert.equal(empty.extractedCount,0);
  process.env.ARTIFACT_TEST_EXPORT_FAIL='1';
  await assert.rejects(callTool(config,'extract_xcode_test_attachments',{sourcePath:bundle}),/help export attachments/);
});

test('manifest validation rejects outside paths and nonfiles',async t=>{
  const f=await fixture(t), exported=path.join(f.directory,'export'), output=path.join(f.directory,'output');
  await fs.mkdir(exported);await fs.mkdir(output);
  const manifest=sampleManifest();manifest[0].attachments[0].exportedFileName='../outside';
  await assert.rejects(prepareAttachments(exported,output,manifest,'/bundle'),/destination/);
  manifest[0].attachments[0].exportedFileName='escape.png';
  const outside=path.join(f.source,'file');await fs.writeFile(outside,'private');await fs.symlink(outside,path.join(exported,'escape.png'));
  await assert.rejects(prepareAttachments(exported,output,manifest,'/bundle'),/outside/);
  await assert.rejects(prepareAttachments(exported,output,{},'/bundle'),/manifest/);
});

test('cancelling an exporter terminates its subprocess and removes private staging',async t=>{
  const f=await fixture(t), command=await commands(t,f), {policy}=await policyFor(f.source);
  const bundle=path.join(f.source,'Example.xcresult');await fs.mkdir(bundle);
  await fs.writeFile(path.join(f.directory,'export-input.json'),'[]');
  process.env.ARTIFACT_TEST_EXPORT_HANG='1';
  const controller=new AbortController();
  const operation=callTool({container:'own-container',container_command:command.container,xcrun_command:command.xcrun,xcode_enabled:true,policy},'extract_xcode_test_attachments',{sourcePath:bundle},controller.signal);
  const timer=setInterval(async()=>{const log=await fs.readFile(command.log,'utf8').catch(()=> '');if(log.includes('xcresulttool'))controller.abort();},20);
  try {await assert.rejects(operation,/cancelled/);}finally{clearInterval(timer);}
  assert.equal(await fs.stat(path.join(f.workdir,'.host-artifacts')).catch(()=>null),null);
  const exported=(await fs.readFile(command.log,'utf8')).trim().split('\n').map(JSON.parse).find(args=>args[0]==='xcresulttool');
  assert.equal(await fs.stat(path.dirname(exported[exported.indexOf('--path')+1])).catch(()=>null),null);
});

test('stdio server initializes, lists tools and reports effective permissions',async t=>{
  const f=await fixture(t), {policy}=await policyFor(f.source);
  const child=spawn(process.execPath,[path.join(root,'mcp/host-artifacts.mjs')],{env:{...process.env,AGENTCTL_HOST_ARTIFACTS_CONFIG:JSON.stringify({container:'own-container',container_command:'/bin/false',policy})},stdio:['pipe','pipe','pipe']});
  t.after(()=>child.kill());
  const lines=(await import('node:readline')).createInterface({input:child.stdout});
  const iterator=lines[Symbol.asyncIterator]();
  const request=async(id,method,params)=>{child.stdin.write(`${JSON.stringify({jsonrpc:'2.0',id,method,params})}\n`);return JSON.parse((await iterator.next()).value);};
  assert.equal((await request(1,'initialize',{protocolVersion:'2025-03-26'})).result.serverInfo.name,'host-artifacts');
  assert.equal((await request(2,'tools/list',{})).result.tools.length,2);
  assert.equal((await request(3,'tools/call',{name:'host_artifacts_status',arguments:{}})).result.structuredContent.container,'own-container');
  assert.equal((await request(4,'tools/call',{name:'import_artifact',arguments:{}})).result.isError,true);
  child.stdin.end();await new Promise(resolve=>child.once('close',resolve));lines.close();
});

for (const paired of [false,true]) guestTest(`managed Unix-socket relay advertises ${paired ? 'Xcode' : 'generic'} tools and imports without host TCP`,async t=>{
  const f=await fixture(t), command=await commands(t,f), {definition}=await policyFor(f.source);
  const source=path.join(f.source,'file.txt');await fs.writeFile(source,'through the relay');
  const socket=path.join(f.directory,'relay.sock'),config=path.join(f.directory,'relay.json');
  await fs.writeFile(config,JSON.stringify({socket_path:socket,nonce:'fixture-nonce',container:'own-container',container_command:command.container,servers:paired ? [definition,{name:'xcode',managed_preset:'xcode',command:'/usr/bin/xcrun',args:['mcpbridge'],shared_process:true}] : [definition],log_path:path.join(f.directory,'relay.log')}));
  let errors='';
  const relay=spawn(process.execPath,[path.join(root,'mcp/host-relay.mjs'),config],{stdio:['ignore','ignore','pipe']});
  relay.stderr.on('data',chunk=>{errors+=chunk;});
  const closed=new Promise(resolve=>relay.once('close',resolve));
  const request=(method,payload,session)=>new Promise((resolve,reject)=>{
    const req=http.request({socketPath:socket,path:'/mcp/host-artifacts',method,headers:{accept:'application/json','content-type':'application/json',...(session?{'mcp-session-id':session}:{})}},response=>{
      let body='';response.on('data',chunk=>{body+=chunk;});response.on('end',()=>resolve({status:response.statusCode,session:response.headers['mcp-session-id'],body:body?JSON.parse(body):null}));
    });req.on('error',reject);req.end(payload?JSON.stringify(payload):undefined);
  });
  try {
    for(let attempt=0;attempt<100 && !(await fs.stat(socket).catch(()=>null));attempt++) await new Promise(resolve=>setTimeout(resolve,10));
    assert.ok((await fs.stat(socket).catch(()=>null))?.isSocket(),errors);
    const initialized=await request('POST',{jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-03-26'}});
    assert.equal(initialized.status,200);assert.equal(initialized.body.result.serverInfo.name,'host-artifacts');
    await request('POST',{jsonrpc:'2.0',method:'notifications/initialized'},initialized.session);
    const listed=await request('POST',{jsonrpc:'2.0',id:3,method:'tools/list',params:{}},initialized.session);
    assert.deepEqual(listed.body.result.tools.map(tool=>tool.name),paired ? ['import_artifact','extract_xcode_test_attachments','host_artifacts_status'] : ['import_artifact','host_artifacts_status']);
    const imported=await request('POST',{jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'import_artifact',arguments:{sourcePath:source,destinationName:'relay.txt'}}},initialized.session);
    assert.equal(imported.status,200);assert.equal(imported.body.result.isError,undefined);
    assert.equal(await fs.readFile(path.join(f.workdir,'.host-artifacts/relay.txt'),'utf8'),'through the relay');
    await request('DELETE',null,initialized.session);
  } finally { relay.kill('SIGTERM');await closed; }
});

test('Xcode extraction is exposed only with the paired built-in integration',async ()=>{
  const generic={policy:{presets:[{name:'xcode'}],grants:[]}};
  assert.deepEqual(availableTools(generic).map(tool=>tool.name),['import_artifact','host_artifacts_status']);
  assert.equal(availableTools({...generic,xcode_enabled:true}).length,3);
  await assert.rejects(callTool(generic,'extract_xcode_test_attachments',{sourcePath:'/bundle.xcresult'}),/Unknown/);
  for (const name of ['extract_test_attachments','extract_test_attachments_from_log']) {
    await assert.rejects(callTool({...generic,xcode_enabled:true},name,{}),/Unknown/);
  }
});

test('retiring presets preserves explicit grants and removes stored preset entries on edit',async t=>{
  const f=await fixture(t), {definition}=await policyFor(f.source);
  const legacy={...definition,presets:['papageye','xcode']};
  const policy=await effectivePolicy([legacy],'/different/home');
  assert.ok(!policy.grants.some(grant=>grant.value.includes('/DerivedData/') || grant.preset==='papageye'));
  assert.equal((await authorizeSource(f.source,policy)).root,f.source);
  const edited=await mutatePolicy([legacy],'allow-preset','xcode');
  assert.deepEqual(edited[0].presets,['xcode']);
  assert.deepEqual(edited[0].grants,definition.grants);
  await assert.rejects(mutatePolicy([definition],'allow-preset','papageye'),/Unknown artifact preset/);
});
