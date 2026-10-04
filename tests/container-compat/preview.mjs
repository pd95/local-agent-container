// Keep terminal diagnostics bounded; complete lossless streams stay in the report.
import fs from 'node:fs';
const path = process.argv[2];
const descriptor = fs.openSync(path, 'r');
const size = fs.fstatSync(descriptor).size;
const buffer = Buffer.alloc(Math.min(size, 4096));
const count = fs.readSync(descriptor, buffer, 0, buffer.length, 0);
fs.closeSync(descriptor);
const bytes = buffer.subarray(0, count);
const text = bytes.toString('utf8');
console.log(`${size} bytes; complete stream: ${path}`);
if (bytes.length === 0) console.log('<empty>');
else if (!Buffer.from(text).equals(bytes) || bytes.some(byte => (byte < 32 && ![9, 10, 13].includes(byte)) || byte === 127)) {
  console.log(`binary preview (first ${Math.min(count, 256)} bytes, hex): ${bytes.subarray(0, 256).toString('hex')}`);
} else {
  process.stdout.write(text);
  if (!text.endsWith('\n')) process.stdout.write('\n');
}
if (size > count) console.log('... preview truncated; see complete stream');
