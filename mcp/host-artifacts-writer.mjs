#!/usr/bin/env node
import fs from 'node:fs/promises';
import {constants} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

async function* frames(input) {
  let pending=Buffer.alloc(0);
  for await (const chunk of input) {
    pending=Buffer.concat([pending,Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)]);
    let newline;
    while ((newline=pending.indexOf(10)) !== -1) {
      if (newline > 100000) throw new Error('Artifact transfer frame is too large');
      const line=pending.subarray(0,newline).toString();
      pending=pending.subarray(newline+1);
      yield JSON.parse(line);
    }
    if (pending.length > 100000) throw new Error('Artifact transfer frame is too large');
  }
  if (pending.length) throw new Error('Incomplete artifact transfer frame');
}

// The writer runs only on Linux. Resolve every parent through an open directory
// descriptor, so replacing a pathname cannot redirect a later write or rename.
class AnchoredFilesystem {
  constructor() { this.directories=new Map(); }
  async anchor(name) {
    if (this.directories.has(name)) return this.directories.get(name);
    const location=name === '/' ? '/' : path.join(`/proc/self/fd/${(await this.anchor(path.dirname(name))).fd}`,path.basename(name));
    const handle=await fs.open(location,constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    this.directories.set(name,handle);
    return handle;
  }
  async location(name) {
    return path.join(`/proc/self/fd/${(await this.anchor(path.dirname(name))).fd}`,path.basename(name));
  }
  async mkdir(name,options) { return fs.mkdir(await this.location(name),options); }
  async lstat(name) { return fs.lstat(await this.location(name)); }
  async open(name,flags,mode) { return fs.open(await this.location(name),flags,mode); }
  async link(source,target) { return fs.link(await this.location(source),await this.location(target)); }
  async rename(source,target) { return fs.rename(await this.location(source),await this.location(target)); }
  async rmdir(name) { return fs.rmdir(await this.location(name)); }
  async mkdtemp(prefix) {
    const generated=await fs.mkdtemp(await this.location(prefix));
    const name=path.join(path.dirname(prefix),path.basename(generated));
    await this.anchor(name);
    return name;
  }
  async remove(name) {
    const stats=await this.lstat(name).catch(error=>{ if (error.code !== 'ENOENT') throw error; });
    if (!stats) return;
    if (stats.isDirectory()) {
      const handle=await this.anchor(name);
      for (const entry of await fs.readdir(`/proc/self/fd/${handle.fd}`)) await this.remove(path.join(name,entry));
      await this.rmdir(name);
      await handle.close(); this.directories.delete(name);
    } else await fs.unlink(await this.location(name));
  }
  async releaseWithin(root) {
    for (const [name,handle] of this.directories) {
      if (name.startsWith(`${root}/`)) {
        await handle.close(); this.directories.delete(name);
      }
    }
  }
  async validate(names) {
    const current=new AnchoredFilesystem();
    try {
      for (const name of names) {
        const before=await (await this.anchor(name)).stat(), after=await (await current.anchor(name)).stat();
        if (before.dev !== after.dev || before.ino !== after.ino) throw new Error('Artifact destination directory changed during transfer');
      }
    } catch (error) {
      throw new Error(`Artifact destination contains a symlink or changed directory: ${error.message}`);
    } finally { await current.close(); }
  }
  async close() { await Promise.all([...this.directories.values()].map(handle=>handle.close())); }
}

function relativeName(value, empty = false) {
  if (typeof value !== 'string' || (!value && !empty) || path.isAbsolute(value) || /[\\\x00-\x1f\x7f]/.test(value) || value.split('/').some(part => ['.','..'].includes(part) || (!part && value !== ''))) throw new Error('Invalid artifact destination path');
  return value;
}
async function directory(disk, root, relative = '') {
  let current = root;
  for (const segment of relative ? relative.split('/') : []) {
    current = path.join(current, segment);
    await disk.mkdir(current, {mode:0o700}).catch(error => { if (error.code !== 'EEXIST') throw error; });
    const stats = await disk.lstat(current);
    if (!stats.isDirectory() || stats.isSymbolicLink()) throw new Error('Artifact destination contains a symlink or non-directory');
    await disk.anchor(current);
  }
  return current;
}
export async function writeArtifacts(workdir, input, output) {
  const disk=new AnchoredFilesystem();
  const base = path.join(workdir, '.host-artifacts');
  let stage, file, expectedSize=0, written=0, totalSize=0, start, complete=false, backup, reserved=false, target;
  let result, retainStage=false;
  try {
    await disk.anchor(workdir);
    for await (const message of frames(input)) {
      if (!start) {
        if (message.op !== 'start' || !['file','directory'].includes(message.kind) || typeof message.overwrite !== 'boolean') throw new Error('Invalid artifact transfer start');
        relativeName(message.destination);
        start=message;
        await directory(disk,workdir, '.host-artifacts');
        const parent = path.posix.dirname(message.destination);
        await directory(disk,base, parent === '.' ? '' : parent);
        target=path.join(base, message.destination);
        const existing = await disk.lstat(target).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
        if (existing?.isSymbolicLink()) throw new Error('Artifact destination must not be a symlink');
        if (existing && !message.overwrite) throw new Error('Artifact destination already exists');
        stage=await disk.mkdtemp(path.join(base,'.stage-'));
        if (message.kind === 'directory') await disk.mkdir(path.join(stage,'item'), {mode:0o700});
        continue;
      }
      if (complete) throw new Error('Unexpected data after artifact transfer finish');
      if (message.op === 'directory') {
        if (start.kind !== 'directory' || file) throw new Error('Invalid directory transfer');
        await directory(disk,path.join(stage,'item'), relativeName(message.path));
        await disk.releaseWithin(stage);
      } else if (message.op === 'file') {
        if (file || !Number.isSafeInteger(message.size) || message.size < 0) throw new Error('Invalid file transfer');
        relativeName(message.path, start.kind === 'file');
        if (start.kind === 'file' && message.path !== '') throw new Error('Invalid file transfer path');
        const destination = start.kind === 'file' ? path.join(stage,'item') : path.join(stage,'item',message.path);
        if (start.kind === 'directory') {
          const parent=path.posix.dirname(message.path);
          await directory(disk,path.join(stage,'item'), parent === '.' ? '' : parent);
        }
        file=await disk.open(destination, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
        expectedSize=message.size; written=0;
      } else if (message.op === 'data') {
        if (!file || typeof message.data !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(message.data)) throw new Error('Invalid artifact data');
        const bytes=Buffer.from(message.data,'base64');
        if (written + bytes.length > expectedSize) throw new Error('Artifact exceeds declared size');
        let offset=0;
        while (offset < bytes.length) { const write=await file.write(bytes,offset,bytes.length-offset); offset+=write.bytesWritten; }
        written+=bytes.length; totalSize+=bytes.length;
      } else if (message.op === 'end-file') {
        if (!file || written !== expectedSize) throw new Error('Incomplete artifact file');
        await file.close(); file=null;
        // Keep publication parents pinned, but don't retain one descriptor per
        // staged directory across a potentially very large bundle import.
        await disk.releaseWithin(stage);
      } else if (message.op === 'finish') {
        if (file) throw new Error('Incomplete artifact transfer');
        await disk.lstat(path.join(stage,'item'));
        complete=true;
      } else throw new Error('Unknown artifact transfer operation');
    }
    if (!complete) throw new Error('Artifact transfer ended before finish');
    // Reject detached/replaced destinations, then publish through pinned parents.
    // A replacement after validation cannot redirect descriptor-relative writes.
    const parent=path.posix.dirname(start.destination);
    await disk.validate([base,path.dirname(target),stage]);
    const existing=await disk.lstat(target).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (existing?.isSymbolicLink()) throw new Error('Artifact destination must not be a symlink');
    if (!start.overwrite && start.kind === 'file') await disk.link(path.join(stage,'item'),target);
    else {
      if (!start.overwrite) { await disk.mkdir(target,{mode:0o700}); reserved=true; }
      else if (existing) { backup=path.join(stage,'previous'); await disk.rename(target,backup); }
      try { await disk.rename(path.join(stage,'item'),target); reserved=false; }
      catch (error) {
        if (backup) {
          try { await disk.rename(backup,target); backup=null; }
          catch {
            retainStage=true;
            throw new Error(`Artifact publication failed; the previous artifact is retained at ${backup}`);
          }
        }
        throw error;
      }
    }
    result={workspacePath:path.posix.join('/workdir/.host-artifacts',start.destination),kind:start.kind,size:totalSize};
  } finally {
    if (file) await file.close();
    try {
      if (reserved) await disk.rmdir(target).catch(()=>{});
      if (stage && !retainStage) await disk.remove(stage);
    } finally { await disk.close(); }
  }
  output.write(`${JSON.stringify(result)}\n`);
  return result;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const stop = () => process.stdin.destroy(new Error('Artifact transfer cancelled'));
  process.once('SIGTERM',stop); process.once('SIGINT',stop);
  try { await writeArtifacts('/workdir',process.stdin,process.stdout); }
  catch (error) { console.error(error.message); process.exitCode=1; }
}
