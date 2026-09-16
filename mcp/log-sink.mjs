#!/usr/bin/env node
import {StringDecoder} from 'node:string_decoder';
import {RotatingLog, DEFAULT_MAX_BYTES} from './rotating-log.mjs';

const [,, logPath, configuredMax] = process.argv;
if (!logPath) {
  console.error('usage: log-sink.mjs LOG_PATH [MAX_BYTES]');
  process.exit(64);
}
const maxBytes = configuredMax ? Number(configuredMax) : DEFAULT_MAX_BYTES;
const log = new RotatingLog(logPath, maxBytes);
const decoder = new StringDecoder('utf8');
let buffered = '';
let dropping = false;
const maxLineChars = 16384;

function writeLine(line, truncated = false) {
  if (line.length > maxLineChars) { line = line.slice(0,maxLineChars); truncated = true; }
  if (truncated) line = `${line} [truncated]`;
  log.write(`${line}\n`);
}

process.stdin.on('data', chunk => {
  buffered += decoder.write(chunk);
  for (;;) {
    const newline = buffered.indexOf('\n');
    if (newline < 0) break;
    if (!dropping) writeLine(buffered.slice(0,newline).replace(/\r$/,''));
    buffered = buffered.slice(newline+1);
    dropping = false;
  }
  if (!dropping && buffered.length > maxLineChars) {
    writeLine(buffered.slice(0,maxLineChars),true);
    buffered = ''; dropping = true;
  } else if (dropping && buffered.length > maxLineChars) {
    buffered = '';
  }
});
process.stdin.on('end', () => {
  buffered += decoder.end();
  if (buffered && !dropping) writeLine(buffered.replace(/\r$/,''));
});
process.stdin.on('error', error => {
  process.stderr.write(`MCP log sink: ${error.message}\n`);
  process.exitCode = 1;
});
