// Require two replies before closing stdin; EOF-only capture would deadlock.
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const [command, ...args] = process.argv.slice(2);
const duration = (name, fallback) => {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`Invalid ${name}`);
  return value;
};
const replyTimeout = duration('COMPAT_PROTOCOL_TIMEOUT_MS', 5000);
const killGrace = duration('COMPAT_PROTOCOL_KILL_GRACE_MS', 10000);
const messages = [
  Buffer.from('{"jsonrpc":"2.0","id":1,"method":"ping"}\n'),
  Buffer.from('{"jsonrpc":"2.0","id":2,"method":"ping"}\n'),
];
// Own the command's process group, including descendants after the child exits.
const child = spawn(command, args, {detached: true, stdio: ['pipe', 'pipe', 'pipe'],
  // Nested capture adapters must remain in this owned group, even if their
  // agentctl parent exits before the protocol client can snapshot descendants.
  env: {...process.env, COMPAT_KEEP_PROCESS_GROUP: '1'}});
let received = Buffer.alloc(0);
let secondSent = false;
let completed = false;
let finishing = false;
let closed = false;
let escalated = false;
let exitCode = 0;
let finalized = false;
let cleanupTimer;
let descendants = [];
const processHelpers = fileURLToPath(new URL('./processes.sh', import.meta.url));
const signalDescendants = signal => {
  for (const pid of descendants) {
    try { process.kill(pid, signal); }
    catch (error) { if (error.code !== 'ESRCH') process.stderr.write(`${error.message}\n`); }
  }
};
const signalGroup = signal => {
  if (!child.pid) return;
  try { process.kill(-child.pid, signal); }
  catch (error) { if (error.code !== 'ESRCH') process.stderr.write(`${error.message}\n`); }
};
const finishIfReaped = () => {
  if (!closed || !escalated || finalized) return;
  finalized = true;
  clearTimeout(cleanupTimer);
  if (exitCode === 0) process.stdout.write(received);
  // The direct child has been reaped and all remaining group members killed.
  process.exitCode = exitCode;
};
const finish = (code, message) => {
  if (finishing) return;
  finishing = true;
  exitCode = code;
  clearTimeout(timer);
  if (message) process.stderr.write(`${message}\n`);
  if (child.pid) {
    const snapshot = spawnSync('bash', ['-c', '. "$1"; compat_descendants "$2"', 'sh', processHelpers, String(child.pid)], {encoding: 'utf8', timeout: 1000});
    if (snapshot.status !== 0) {
      exitCode = 1;
      process.stderr.write('Unable to snapshot protocol command descendants\n');
    }
    descendants = (snapshot.stdout ?? '').trim().split(/\s+/).filter(value => /^[0-9]+$/.test(value)).map(Number);
  }
  child.stdin.destroy();
  signalDescendants('SIGTERM');
  signalGroup('SIGTERM');
  if (code === 0 && closed && descendants.length === 0) {
    signalGroup('SIGKILL');
    escalated = true;
    finishIfReaped();
    return;
  }
  cleanupTimer = setTimeout(() => {
    signalDescendants('SIGKILL');
    // Give the direct child a turn to reap killed descendants before escalation.
    cleanupTimer = setTimeout(() => {
      signalGroup('SIGKILL');
      escalated = true;
      finishIfReaped();
    }, 100);
  }, killGrace);
};
const fail = message => finish(1, message);
const timer = setTimeout(() => fail('No protocol reply while stdin was open'), replyTimeout);
process.on('SIGINT', () => finish(130, 'Protocol client interrupted'));
process.on('SIGTERM', () => finish(130, 'Protocol client interrupted'));
child.on('error', error => fail(error.message));
child.stdin.on('error', error => fail(error.message));
child.stderr.pipe(process.stderr);
child.stdout.on('data', chunk => {
  if (finishing) return;
  received = Buffer.concat([received, chunk]);
  if (received.length > messages[0].length + messages[1].length) return fail('Unexpected extra protocol bytes');
  if (!secondSent && received.length >= messages[0].length) {
    if (!received.subarray(0, messages[0].length).equals(messages[0])) return fail('First protocol reply differs');
    if (child.stdin.destroyed || child.stdin.writableEnded) return fail('stdin closed before first reply');
    secondSent = true;
    child.stdin.write(messages[1]);
  }
  if (secondSent && received.length >= messages[0].length + messages[1].length && !completed) {
    if (!received.equals(Buffer.concat(messages))) return fail('Protocol bytes differ');
    completed = true;
    child.stdin.end();
  }
});
child.on('close', (code, signal) => {
  closed = true;
  if (!finishing) {
    if (code !== 0 || signal || !completed) fail(`Protocol command exited prematurely (${code}, ${signal})`);
    else finish(0);
  }
  finishIfReaped();
});
child.stdin.write(messages[0]);
