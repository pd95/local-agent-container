// Identical byte protocol for host and guest sockets; no external services.
import net from 'node:net';
import fs from 'node:fs';
const [mode, target, port] = process.argv.slice(2);
if (mode === 'server' || mode === 'tcp-server') {
  const server = net.createServer(socket => socket.pipe(socket));
  const endpoint = mode === 'server' ? target : {host: target, port: Number(port)};
  server.listen(endpoint, () => {
    if (mode === 'server') fs.chmodSync(target, 0o777);
    process.stdout.write(`${JSON.stringify(server.address())}\n`);
  });
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => server.close(() => process.exit(0)));
} else if (mode === 'client' || mode === 'tcp-client') {
  const socket = net.createConnection(mode === 'client' ? target : {host: target, port: Number(port)});
  const expected = Buffer.from('compat-socket-roundtrip\n');
  const parts = [];
  let settled = false;
  const finish = (error) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    if (error) process.stderr.write(`${mode} ${target}: ${error}; received=${Buffer.concat(parts).toString('hex')}\n`);
    socket.destroy();
    process.exit(error ? 1 : 0);
  };
  const timer = setTimeout(() => finish('timed out waiting for echo after 3000ms'), 3000);
  socket.on('connect', () => socket.write(expected));
  socket.on('data', part => {
    parts.push(part);
    const actual = Buffer.concat(parts);
    if (actual.length >= expected.length) finish(actual.equals(expected) ? null : 'echo bytes differ');
  });
  socket.on('end', () => finish('connection ended before the complete echo'));
  socket.on('error', error => finish(error.message));
} else throw new Error(`Unknown mode: ${mode}`);
