import fs from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';

const kinds = new Set(['file', 'directory', 'file-pattern', 'directory-pattern']);
const presetNames = new Set(['xcode', 'papageye']);
const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
export const inside = (candidate, root) => {
  const relative = path.relative(root, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
};
function text(value, label) {
  if (typeof value !== 'string' || !value || /[\x00-\x1f\x7f]/.test(value)) throw new Error(`${label} must be a nonempty string without control characters`);
  return value;
}
export function pattern(value) {
  text(value, 'Pattern');
  if (value.length > 4096) throw new Error('Pattern is too long');
  try { return new RegExp(`^(?:${value})$`); }
  catch { throw new Error('Invalid JavaScript regular expression'); }
}
export function grantId(kind, value) {
  return `grant-${createHash('sha256').update(`${kind}\0${value}`).digest('hex').slice(0, 24)}`;
}
export async function normalizeGrant(grant, {existing = false, base = process.cwd()} = {}) {
  if (!grant || typeof grant !== 'object' || Array.isArray(grant) || Object.keys(grant).some(key => !['kind','value','id'].includes(key)) || !kinds.has(grant.kind)) throw new Error('Invalid artifact grant');
  let value = text(grant.value, 'Grant value');
  if (grant.kind.endsWith('-pattern')) pattern(value);
  else if (existing) {
    if (!path.isAbsolute(value) || path.normalize(value) !== value) throw new Error('Stored artifact grant must be a canonical absolute path');
  } else {
    value = await fs.realpath(path.resolve(base, value));
    const stats = await fs.stat(value);
    if (grant.kind === 'file' ? !stats.isFile() : !stats.isDirectory()) throw new Error(`Grant must refer to a ${grant.kind}`);
  }
  const id = grantId(grant.kind, value);
  if (grant.id !== undefined && grant.id !== id) throw new Error('Invalid artifact grant ID');
  return {id, kind:grant.kind, value};
}
export async function normalizeDefinition(value, options = {}) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !['name','type','presets','grants'].includes(key)) || value.type !== 'builtin' || value.name !== 'host-artifacts') throw new Error('Invalid host-artifacts definition');
  const presets = value.presets ?? [];
  const grants = value.grants ?? [];
  if (!Array.isArray(presets) || presets.some(item => !presetNames.has(item)) || !Array.isArray(grants)) throw new Error('Invalid artifact presets or grants');
  const normalized = await Promise.all(grants.map(grant => normalizeGrant(grant, options)));
  return {name:'host-artifacts', transport:'stdio', builtin:'host-artifacts', shared_process:true, env_vars:[], presets:[...new Set(presets)].sort(), grants:[...new Map(normalized.map(grant => [grant.id, grant])).values()].sort((a,b) => a.id.localeCompare(b.id))};
}
export function isXcodePreset(definition) {
  return definition.managed_preset === 'xcode' || (definition.name === 'xcode' && definition.command === '/usr/bin/xcrun' && JSON.stringify(definition.args) === '["mcpbridge"]' && definition.shared_process === true);
}
export function presetGrants(name, home) {
  const homePattern = escape(home);
  const rules = name === 'xcode' ? [
    ['file-pattern', '^/(?:private/)?var/folders/.*/ActionArtifacts/[^/]+/RenderPreview/RenderPreview[^/]*\\.png$'],
    ['file-pattern', '^/(?:private/)?var/folders/.*/ActionArtifacts/[^/]+/DeviceInteractionSynthesize/[^/]+\\.(?:png|txt)$'],
    ['file-pattern', '^/(?:private/)?var/folders/.*/ActionArtifacts/[^/]+/(?:GetBuildLog|RunAllTests|RunSomeTests)/[^/]+\\.txt$'],
    ['directory-pattern', `^${homePattern}/Library/Developer/Xcode/DerivedData/[^/]+/Logs/Test/Test-[^/]+\\.xcresult$`]
  ] : name === 'papageye' ? [
    ['file-pattern', `^${homePattern}/Library/Application Support/PapagEye/Screenshots/[^/]+\\.(?:png|jpg|jpeg|json)$`],
    ['file-pattern', `^${homePattern}/Library/Application Support/PapagEye/AuditLogs/[^/]+\\.jsonl$`]
  ] : [];
  if (!rules.length) throw new Error('Unknown artifact preset');
  return rules.map(([kind,value], index) => ({id:`${name}-${index + 1}`,kind,value,preset:name}));
}
export async function effectivePolicy(definitions, home) {
  const definition = definitions.find(item => item.builtin === 'host-artifacts');
  if (!definition) throw new Error('Managed host-artifacts is not enabled');
  const explicit = await normalizeDefinition({name:'host-artifacts',type:'builtin',presets:definition.presets,grants:definition.grants}, {existing:true});
  const grants = explicit.grants.map(grant => ({...grant,origin:'explicit'}));
  const presets = explicit.presets.map(name => ({id:`preset:${name}`,name,origin:'explicit'}));
  if (definitions.some(isXcodePreset) && !explicit.presets.includes('xcode')) presets.push({id:'automatic:xcode',name:'xcode',origin:'automatic'});
  for (const preset of presets) for (const grant of presetGrants(preset.name, home)) grants.push({...grant,origin:preset.origin});
  return {presets,grants};
}
export async function authorizeSource(value, policy, requiredKind) {
  text(value, 'Source path');
  if (!path.isAbsolute(value)) throw new Error('Source path must be absolute');
  const sourcePath = await fs.realpath(value);
  const stats = await fs.stat(sourcePath);
  const kind = stats.isFile() ? 'file' : stats.isDirectory() ? 'directory' : null;
  if (!kind || (requiredKind && requiredKind !== kind)) throw new Error(`Source must be a ${requiredKind || 'regular file or directory'}`);
  for (const grant of policy.grants) {
    if (grant.kind === 'file' && kind === 'file' && sourcePath === grant.value) return {sourcePath,stats,kind,root:sourcePath};
    if (grant.kind === 'file-pattern' && kind === 'file' && pattern(grant.value).test(sourcePath)) return {sourcePath,stats,kind,root:sourcePath};
    if (grant.kind === 'directory' && inside(sourcePath, grant.value)) {
      const rootStats = await fs.lstat(grant.value).catch(() => null);
      if (rootStats?.isDirectory() && !rootStats.isSymbolicLink() && await fs.realpath(grant.value) === grant.value) return {sourcePath,stats,kind,root:grant.value};
    }
    if (grant.kind === 'directory-pattern') {
      const matcher = pattern(grant.value);
      let ancestor = kind === 'directory' ? sourcePath : path.dirname(sourcePath);
      for (;;) {
        if (matcher.test(ancestor)) return {sourcePath,stats,kind,root:ancestor};
        const parent = path.dirname(ancestor);
        if (parent === ancestor) break;
        ancestor = parent;
      }
    }
  }
  throw new Error('Source path is not authorized by host-artifacts grants');
}
export async function mutatePolicy(definitions, action, value, home) {
  const definition = definitions.find(item => item.builtin === 'host-artifacts');
  if (!definition) throw new Error('Managed host-artifacts is not enabled');
  const normalized = await normalizeDefinition({name:'host-artifacts',type:'builtin',presets:definition.presets,grants:definition.grants}, {existing:true});
  if (action.startsWith('allow-') && action !== 'allow-preset') {
    const grant = await normalizeGrant({kind:action.slice(6),value});
    normalized.grants = [...new Map([...normalized.grants,grant].map(item => [item.id,item])).values()].sort((a,b) => a.id.localeCompare(b.id));
  } else if (action === 'allow-preset') {
    if (!presetNames.has(value)) throw new Error('Unknown artifact preset');
    normalized.presets = [...new Set([...normalized.presets,value])].sort();
  } else if (action === 'revoke') {
    if (value.startsWith('preset:') && normalized.presets.includes(value.slice(7))) normalized.presets = normalized.presets.filter(item => item !== value.slice(7));
    else if (normalized.grants.some(item => item.id === value)) normalized.grants = normalized.grants.filter(item => item.id !== value);
    else throw new Error('Explicit grant not found; automatic Xcode grants are removed by removing the built-in xcode definition');
  } else throw new Error('Unknown artifact permission action');
  return definitions.map(item => item === definition ? {...definition,presets:normalized.presets,grants:normalized.grants} : item);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    let input = '';
    for await (const chunk of process.stdin) input += chunk;
    const value = JSON.parse(input);
    const [,,action,argument] = process.argv;
    const result = action === 'normalize' ? await normalizeDefinition(value, {base:argument || process.cwd()}) :
      action === 'list' ? await effectivePolicy(value, process.env.HOME) :
      await mutatePolicy(value, action, argument, process.env.HOME);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) { console.error(error.message); process.exitCode=1; }
}
