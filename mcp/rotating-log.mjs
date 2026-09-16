import fs from 'node:fs';

export const DEFAULT_MAX_BYTES = 5 * 1024 * 1024;

export class RotatingLog {
  constructor(path, maxBytes = DEFAULT_MAX_BYTES) {
    this.path = path || null;
    this.maxBytes = Number.isSafeInteger(maxBytes) && maxBytes > 0 ? maxBytes : DEFAULT_MAX_BYTES;
  }

  write(line) {
    if (!this.path) {
      process.stderr.write(line);
      return;
    }
    const data = Buffer.from(line);
    let size = 0;
    try { size = fs.statSync(this.path).size; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (size > 0 && size + data.length > this.maxBytes) {
      const previous = `${this.path}.1`;
      try { fs.unlinkSync(previous); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      fs.renameSync(this.path, previous);
    }
    fs.appendFileSync(this.path, data, {mode:0o600});
    fs.chmodSync(this.path, 0o600);
  }
}

export function writeEvent(log, level, event, fields = {}) {
  const payload = {level, event, ...fields};
  log.write(`${new Date().toISOString()} [agentctl-mcp-event] ${JSON.stringify(payload)}\n`);
}

export function writeServerStderr(log, server, pid, message, truncated = false) {
  log.write(`${new Date().toISOString()} [agentctl-mcp-stderr] ${JSON.stringify({server,pid,message,truncated})}\n`);
}
