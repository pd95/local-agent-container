// A read-only OCI registry fixture, bound exclusively to host loopback.
import http from 'node:http';
import {readFileSync, appendFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const [layerPath, architecture, repository, requestLog] = process.argv.slice(2);
if (!['arm64', 'amd64'].includes(architecture) || !/^[a-z0-9-]+$/.test(repository)) throw new Error('Invalid registry fixture arguments');
const digest = bytes => `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
const layer = readFileSync(layerPath);
const config = Buffer.from(JSON.stringify({architecture, os: 'linux', config: {}, rootfs: {type: 'layers', diff_ids: [digest(layer)]}}));
const descriptor = (bytes, mediaType) => ({mediaType, digest: digest(bytes), size: bytes.length});
const manifestType = 'application/vnd.oci.image.manifest.v1+json';
const manifest = Buffer.from(JSON.stringify({schemaVersion: 2, mediaType: manifestType,
  config: descriptor(config, 'application/vnd.oci.image.config.v1+json'),
  layers: [descriptor(layer, 'application/vnd.oci.image.layer.v1.tar')]}));
// Serve an explicit index: Apple may synthesize an index for a lone manifest.
const indexType = 'application/vnd.oci.image.index.v1+json';
const index = Buffer.from(JSON.stringify({schemaVersion: 2, mediaType: indexType,
  manifests: [{...descriptor(manifest, manifestType), platform: {architecture, os: 'linux'}}]}));
const routes = new Map([
  ['/v2/', {body: Buffer.from('{}'), type: 'application/json'}],
  [`/v2/${repository}/manifests/latest`, {body: index, type: indexType}],
  [`/v2/${repository}/manifests/${digest(index)}`, {body: index, type: indexType}],
  [`/v2/${repository}/manifests/${digest(manifest)}`, {body: manifest, type: manifestType}],
  [`/v2/${repository}/blobs/${digest(config)}`, {body: config, type: 'application/octet-stream'}],
  [`/v2/${repository}/blobs/${digest(layer)}`, {body: layer, type: 'application/octet-stream'}],
]);
const server = http.createServer((request, response) => {
  const path = new URL(request.url, 'http://127.0.0.1').pathname;
  appendFileSync(requestLog, `${request.method} ${path}\n`);
  const route = routes.get(path);
  if (!route || !['GET', 'HEAD'].includes(request.method)) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, {'Content-Type': route.type, 'Content-Length': route.body.length,
    'Docker-Distribution-Api-Version': 'registry/2.0', 'Docker-Content-Digest': digest(route.body)});
  response.end(request.method === 'HEAD' ? undefined : route.body);
});
server.listen(0, '127.0.0.1', () => console.log(JSON.stringify({...server.address(), index_digest: digest(index), manifest_digest: digest(manifest), layer_digest: digest(layer), config_digest: digest(config)})));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
