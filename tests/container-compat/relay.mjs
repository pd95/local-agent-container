// Forward a growing regular diagnostic file; no FIFO or inherited pipe EOF.
import fs from 'node:fs';

const source = fs.openSync(process.argv[2], 'r');
const complete = process.argv[3];
let forwarding = true;
let offset = 0;
let blocked = false;
let completedAt = null;
let finalSize = null;
process.stdout.on('error', (error) => {
  if (error.code !== 'EPIPE') {
    console.error(error);
    process.exitCode = 1;
  }
  forwarding = false;
  blocked = false;
});
process.stdout.on('drain', () => { blocked = false; });
const timer = setInterval(() => {
  if (completedAt === null && fs.existsSync(complete)) {
    completedAt = Date.now();
    finalSize = fs.fstatSync(source).size;
  }
  // A consumer that keeps its pipe open without reading cannot hang cleanup.
  if (blocked && completedAt !== null && Date.now() - completedAt > 5000) process.exit(1);
  if (blocked) return;
  if (finalSize !== null && offset >= finalSize) {
    clearInterval(timer);
    fs.closeSync(source);
    return;
  }
  const chunk = Buffer.allocUnsafe(65536);
  const count = fs.readSync(source, chunk, 0, chunk.length, offset);
  if (count > 0) {
    offset += count;
    if (forwarding && !process.stdout.write(chunk.subarray(0, count))) blocked = true;
  } else if (fs.existsSync(complete)) {
    clearInterval(timer);
    fs.closeSync(source);
  }
}, 10);
