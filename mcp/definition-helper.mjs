#!/usr/bin/env node
import http from 'node:http';
import {isIP} from 'node:net';

const [,, command] = process.argv;
const input = await new Promise((resolve, reject) => {
  let text = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => { text += chunk; });
  process.stdin.on('end', () => resolve(text));
  process.stdin.on('error', reject);
});

function fail(message) {
  console.error(message);
  process.exit(1);
}

function objectOfStrings(value, label) {
  if (value === undefined) return {};
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`);
  for (const [key, item] of Object.entries(value)) {
    if (typeof item !== 'string') fail(`${label} values must be strings`);
    try { http.validateHeaderName(key); } catch { fail(`invalid header name in ${label}`); }
  }
  return value;
}

function validIdentifier(value) {
  return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(value);
}

function validEnvironmentName(value) {
  return typeof value === 'string' && /^[A-Za-z_][A-Za-z0-9_]*$/.test(value);
}

function loopbackHostname(hostname) {
  const unbracketed = hostname.startsWith('[') && hostname.endsWith(']') ? hostname.slice(1,-1) : hostname;
  const lower = unbracketed.toLowerCase();
  if (lower === 'localhost' || lower === 'localhost.') return true;
  if (isIP(unbracketed) === 4) return unbracketed.startsWith('127.');
  return isIP(unbracketed) === 6 && unbracketed === '::1';
}

if (command === 'validate-header-value') {
  try { http.validateHeaderValue(process.argv[3] || 'x-agentctl-value', input); }
  catch { fail('invalid header value'); }
  process.exit(0);
}
if (command !== 'normalize-http') fail('unknown definition helper command');
let definition;
try { definition = JSON.parse(input); } catch { fail('definition must be valid JSON'); }
if (!definition || typeof definition !== 'object' || Array.isArray(definition)) fail('server must be an object');
const allowed = new Set(['name', 'type', 'url', 'headers', 'header_env_vars', 'header_keychain_credentials', 'bearer_token_env_var', 'bearer_token_keychain']);
if (Object.keys(definition).some(key => !allowed.has(key))) fail('unknown HTTP definition field');
if (!validIdentifier(definition.name)) fail('invalid server name');
if (definition.type !== 'http') fail('HTTP definition type must be http');
if (typeof definition.url !== 'string' || /[\u0000-\u001f\u007f]/.test(definition.url) || definition.url.includes('#') || /^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^/]*@/.test(definition.url)) fail('invalid HTTP upstream URL');
let url;
try { url = new URL(definition.url); } catch { fail('invalid HTTP upstream URL'); }
if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.hash) fail('invalid HTTP upstream URL');
if (url.protocol === 'http:' && !loopbackHostname(url.hostname)) fail('plaintext HTTP upstreams must use host loopback');
if (['/.well-known/agentctl-mcp-health','/.well-known/agentctl-mcp-proxy-health'].includes(url.pathname)) fail('managed health paths cannot be HTTP upstreams');

const headers = objectOfStrings(definition.headers, 'headers');
const headerEnvVars = objectOfStrings(definition.header_env_vars, 'header_env_vars');
const headerKeychainCredentials = objectOfStrings(definition.header_keychain_credentials, 'header_keychain_credentials');
const reserved = new Set(['host', 'content-length', 'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade']);
const sources = new Map();
for (const [name, value] of Object.entries(headers)) {
  try { http.validateHeaderValue(name, value); } catch { fail('invalid literal header value'); }
  if (/[\u0000-\u001f\u007f]/.test(value)) fail('invalid literal header value');
  const lower = name.toLowerCase();
  if (reserved.has(lower)) fail('reserved header name');
  if (sources.has(lower)) fail('duplicate configured header');
  sources.set(lower, 'literal');
}
for (const [name, envName] of Object.entries(headerEnvVars)) {
  const lower = name.toLowerCase();
  if (reserved.has(lower) || sources.has(lower)) fail('duplicate or reserved configured header');
  if (!validEnvironmentName(envName)) fail('invalid header environment variable name');
  sources.set(lower, 'environment');
}
for (const [name, credential] of Object.entries(headerKeychainCredentials)) {
  const lower = name.toLowerCase();
  if (reserved.has(lower) || sources.has(lower)) fail('duplicate or reserved configured header');
  if (!validIdentifier(credential)) fail('invalid Keychain credential identifier');
  sources.set(lower, 'keychain');
}
if (definition.bearer_token_env_var !== undefined && !validEnvironmentName(definition.bearer_token_env_var)) fail('invalid bearer token environment variable name');
if (definition.bearer_token_keychain !== undefined && !validIdentifier(definition.bearer_token_keychain)) fail('invalid bearer token Keychain identifier');
if (definition.bearer_token_env_var && definition.bearer_token_keychain) fail('duplicate bearer token sources');
if ((definition.bearer_token_env_var || definition.bearer_token_keychain) && sources.has('authorization')) fail('duplicate Authorization source');

const lowerObject = object => Object.fromEntries(Object.entries(object).sort(([a], [b]) => a.toLowerCase().localeCompare(b.toLowerCase())).map(([key, value]) => [key.toLowerCase(), value]));
process.stdout.write(JSON.stringify({
  name: definition.name,
  transport: 'http',
  url: url.href,
  headers: lowerObject(headers),
  header_env_vars: lowerObject(headerEnvVars),
  header_keychain_credentials: lowerObject(headerKeychainCredentials),
  bearer_token_env_var: definition.bearer_token_env_var || null,
  bearer_token_keychain: definition.bearer_token_keychain || null
}));
