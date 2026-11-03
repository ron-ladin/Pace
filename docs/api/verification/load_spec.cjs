// Assembles the split contract into one object, in the shape of a single OpenAPI file, so that
// checks always read the current files and never a stale bundle. It needs no Docker.
// docs/api/openapi.yaml is the root, with its path items in paths/ and its components in components/.
const fs = require('fs');
const path = require('path');

const GROUPS = ['parameters', 'headers', 'responses', 'examples', 'schemas'];

function rewriteRefs(node, group) {
  if (Array.isArray(node)) return node.map(n => rewriteRefs(n, group));
  if (!node || typeof node !== 'object') return node;
  const out = {};
  for (const [k, v] of Object.entries(node)) {
    out[k] = k === '$ref' && typeof v === 'string' ? localRef(v, group) : rewriteRefs(v, group);
  }
  return out;
}

function localRef(ref, group) {
  const external = ref.match(/^(?:\.\.\/components\/|\.\/)(\w+)\.yaml#\/([^/]+)$/);
  if (external && GROUPS.includes(external[1])) return `#/components/${external[1]}/${external[2]}`;
  const internal = ref.match(/^#\/([^/]+)$/);
  if (internal && group) return `#/components/${group}/${internal[1]}`;
  throw new Error(`Unrecognized $ref: ${ref}`);
}

function loadSpec(YAML, apiDir) {
  const texts = [];
  const load = rel => {
    const text = fs.readFileSync(path.join(apiDir, rel), 'utf8').replace(/\r\n/g, '\n');
    texts.push(text);
    return YAML.parse(text);
  };
  const spec = load('openapi.yaml');
  const pathFiles = new Map();
  const used = new Set();
  const paths = {};
  for (const [p, item] of Object.entries(spec.paths)) {
    const m = typeof item.$ref === 'string' && item.$ref.match(/^(paths\/[\w-]+\.yaml)#\/(.+)$/);
    if (!m) throw new Error(`Path ${p} must be a $ref into paths/`);
    if (!pathFiles.has(m[1])) pathFiles.set(m[1], load(m[1]));
    const key = m[2].replace(/~1/g, '/').replace(/~0/g, '~');
    const target = pathFiles.get(m[1])[key];
    if (key !== p || !target) throw new Error(`${item.$ref} does not resolve to path ${p}`);
    used.add(`${m[1]} ${key}`);
    paths[p] = rewriteRefs(target, null);
  }
  for (const name of fs.readdirSync(path.join(apiDir, 'paths'))) {
    const rel = `paths/${name}`;
    if (!pathFiles.has(rel)) throw new Error(`${rel} is not referenced by the root`);
    for (const key of Object.keys(pathFiles.get(rel))) {
      if (!used.has(`${rel} ${key}`)) throw new Error(`${rel} defines ${key}, which the root does not reference`);
    }
  }
  const components = { ...spec.components };
  for (const group of GROUPS) components[group] = rewriteRefs(load(`components/${group}.yaml`), group);
  return { spec: { ...spec, paths, components }, text: texts.join('\n') };
}

module.exports = { loadSpec };
