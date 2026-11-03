// Checks the API contract against the design documents, and every example against its schema.
// Usage: node check_coverage.mjs <directory with yaml, ajv and ajv-formats installed> <repository root>
// Exit code 0 means every check passed.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const depsDir = path.resolve(process.argv[2]);
const root = path.resolve(process.argv[3]);
const require = createRequire(path.join(depsDir, 'package.json'));
const YAML = require('yaml');
const Ajv2020 = require('ajv/dist/2020').default;
const addFormats = require('ajv-formats').default;
const localRequire = createRequire(import.meta.url);
const { readSplitDoc } = localRequire('../../design/verification/read_split_doc.cjs');
const { loadSpec } = localRequire('./load_spec.cjs');

const read = p => readSplitDoc(path.join(root, p));
const { spec, text: specText } = loadSpec(YAML, path.join(root, 'docs/api'));
const apiMd = read('docs/design/api.md');
const dbMd = read('docs/design/database.md');
const arch = read('ARCHITECTURE.md');

const failures = [];
const fail = m => failures.push(m);
const pass = m => console.log(`PASS ${m}`);
function check(name, before) {
  const added = failures.length - before;
  if (added === 0) pass(name);
  else console.log(`FAIL ${name}: ${added} problem(s)`);
}

const METHODS = ['get', 'put', 'post', 'patch', 'delete'];
const ops = [];
for (const [p, item] of Object.entries(spec.paths)) {
  for (const m of METHODS) if (item[m]) ops.push({ key: `${m.toUpperCase()} ${p}`, method: m, path: p, op: item[m] });
}
const opByKey = new Map(ops.map(o => [o.key, o]));
const resolve = o => {
  if (!o || !o.$ref) return o;
  return o.$ref.replace('#/', '').split('/').reduce((a, k) => a[k], spec);
};
const responseOf = r => resolve(r);
const codesOfResponse = r => {
  const media = responseOf(r).content?.['application/problem+json'];
  if (!media) return [];
  return Object.values(media.examples || {}).map(e => resolve(e).value.code);
};

// ---------- 1. Every operation is complete ----------
let n = failures.length;
const ids = new Set();
const PATTERNS = ['R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'W1', 'W2', 'W3', 'W4', 'W5', 'W6'];
for (const { key, op } of ops) {
  if (!op.operationId || ids.has(op.operationId)) fail(`${key}: missing or duplicate operationId`);
  ids.add(op.operationId);
  if (!Array.isArray(op.security) || !op.security.length) fail(`${key}: no explicit security`);
  const statuses = Object.keys(op.responses);
  if (!statuses.some(s => /^2/.test(s))) fail(`${key}: no success response`);
  if (!statuses.some(s => /^4/.test(s))) fail(`${key}: no 4xx response`);
  for (const p of op['x-access-patterns'] || []) if (!PATTERNS.includes(p)) fail(`${key}: unknown pattern ${p}`);
  if (!(op['x-access-patterns'] || []).length) fail(`${key}: no x-access-patterns`);
  if (!op.description) fail(`${key}: no description`);
}
check(`every one of ${ops.length} operations has an ID, auth rule, success, error cases and pattern`, n);

// ---------- 2. Examples conform to schemas ----------
n = failures.length;
const ajv = new Ajv2020({ strict: false, allErrors: true, allowUnionTypes: true });
addFormats(ajv);
const rewrite = x => {
  if (Array.isArray(x)) return x.map(rewrite);
  if (x && typeof x === 'object') {
    const o = {};
    for (const [k, v] of Object.entries(x)) {
      o[k] = k === '$ref' && typeof v === 'string' && v.startsWith('#/') ? `pace${v}` : rewrite(v);
    }
    return o;
  }
  return x;
};
ajv.addSchema({ $id: 'pace', components: { schemas: rewrite(spec.components.schemas) } });
const compile = schema => ajv.compile(rewrite(schema));
let exampleCount = 0;
function checkMedia(where, media, expectedStatus) {
  for (const [type, m] of Object.entries(media || {})) {
    if (!m.schema) continue;
    if (type === 'application/gpx+xml') continue; // A raw string schema: checked by Spectral only.
    const list = [];
    if (m.example !== undefined) list.push(['example', m.example]);
    for (const [k, e] of Object.entries(m.examples || {})) list.push([k, resolve(e).value]);
    if (!list.length && /json/.test(type) && !where.includes('components')) fail(`${where} ${type}: no example`);
    const validate = compile(m.schema);
    for (const [name, value] of list) {
      exampleCount++;
      if (!validate(value)) fail(`${where} ${type} ${name}: ${ajv.errorsText(validate.errors)}`);
      if (expectedStatus && value.status !== Number(expectedStatus)) fail(`${where} ${name}: status ${value.status} in a ${expectedStatus} response`);
    }
  }
}
for (const { key, op } of ops) {
  if (op.requestBody) checkMedia(`${key} request`, resolve(op.requestBody).content);
  for (const [status, r] of Object.entries(op.responses)) {
    checkMedia(`${key} ${status}`, responseOf(r).content, /^[45]/.test(status) ? status : null);
  }
}
const control = compile({ $ref: '#/components/schemas/CurrentUser' });
if (control({ id: 'not-a-uuid' })) fail('negative control: a broken example was accepted');
const controlRule = compile({ $ref: '#/components/schemas/RuleRequest' });
if (controlRule({ type: 'fastest_pace' })) fail('negative control: fastest_pace without minDistanceMeters was accepted');
if (controlRule({ type: 'longest_run', minDistanceMeters: 5000 })) fail('negative control: longest_run with minDistanceMeters was accepted');
if (!controlRule({ type: 'fastest_pace', minDistanceMeters: 5000 })) fail('negative control: a correct rule was refused');
check(`all ${exampleCount} examples conform to their schemas (negative controls rejected)`, n);

// ---------- 3. All access patterns are served ----------
n = failures.length;
const served = new Set(ops.flatMap(o => o.op['x-access-patterns'] || []));
for (const p of PATTERNS) if (!served.has(p)) fail(`pattern ${p} has no operation`);
const covSection = sectionOf(apiMd, '## 20.');
for (const p of PATTERNS) {
  if (!new RegExp(`^\\| ${p} \\|`, 'm').test(covSection)) fail(`pattern ${p} is missing from the mapping table in api.md`);
}
check('every R1-R8 and W1-W6 pattern has an operation and a row in the mapping table', n);

// ---------- 4. All Phase 1 functional requirements are mapped ----------
n = failures.length;
const FR = [
  'Register', 'Log in', 'Log out', 'Edit profile: display name, photo, birth date, city', 'Set run privacy', 'Delete account',
  'Upload a GPX file', 'Compute distance, duration and pace', 'Reject duplicates', 'Reject overlapping runs', 'Reject future runs', 'Reject runs older than the limit',
  'Store implausible runs as invalid', 'View history', 'Personal stats', 'Users cannot delete runs',
  'Send a friend request', 'Accept a friend request', 'Decline a friend request', 'Remove a friend',
  'Create a public or private group', 'Group roles', 'Search public groups by name and area',
  'Create a competition', 'Join a competition', 'Leave a competition', 'Backfill on join', 'Public top N consent', 'Leaderboard updates after each run',
  'Finalizing state', 'Final result', 'Rule types', 'Run evaluated against all active competitions',
];
for (const label of FR) {
  const row = covSection.split('\n').find(l => l.startsWith(`| ${label} |`));
  if (!row) { fail(`requirement "${label}" is missing from the mapping table`); continue; }
  if (!/`(GET|PUT|POST|PATCH|DELETE) \//.test(row) && !/No endpoint/.test(row)) fail(`requirement "${label}" names no endpoint`);
}
check(`all ${FR.length} Phase 1 requirement rows name an endpoint, or say why there is none`, n);

// ---------- 5. The catalog in api.md matches the spec exactly ----------
n = failures.length;
const AUTO = new Set(['csrf_rejected', 'malformed_request', 'invalid_cursor', 'payload_too_large', 'unsupported_media_type', 'validation_failed', 'unauthenticated', 'rate_limited', 'internal_error', 'temporarily_unavailable']);
const catalog = sectionOf(apiMd, '## 4.');
const seen = new Set();
for (const line of catalog.split('\n')) {
  const m = line.match(/^\| `(GET|PUT|POST|PATCH|DELETE) (\/[^`]*)` \|/);
  if (!m) continue;
  const cols = line.split(/(?<!\\)\|/).map(c => c.trim());
  if (cols.length !== 8) continue; // Another table in this section, such as "added endpoints".
  const key = `${m[1]} ${m[2]}`;
  seen.add(key);
  const o = opByKey.get(key);
  if (!o) { fail(`catalog row is not in the spec: ${key}`); continue; }
  const [, , auth, , success, errors, serves] = cols;
  const sec = o.op.security;
  const want = sec.length === 2 ? 'O' : Object.keys(sec[0]).length ? 'A' : 'N';
  if (auth !== want) fail(`${key}: catalog says auth ${auth}, the spec says ${want}`);
  for (const st of success.match(/\b[1-5]\d\d\b/g) || []) if (!o.op.responses[st]) fail(`${key}: success ${st} is not in the spec`);
  for (const st of Object.keys(o.op.responses).filter(s => /^[23]/.test(s))) if (!success.includes(st)) fail(`${key}: spec success ${st} is not in the catalog`);
  const inSpec = new Set(Object.values(o.op.responses).flatMap(codesOfResponse).filter(c => !AUTO.has(c)));
  const inRow = new Set((errors.match(/`[a-z_]+`/g) || []).map(c => c.slice(1, -1)));
  for (const c of inRow) if (!inSpec.has(c)) fail(`${key}: catalog error ${c} is not in the spec`);
  for (const c of inSpec) if (!inRow.has(c)) fail(`${key}: spec error ${c} is not in the catalog`);
  const a = [...(o.op['x-access-patterns'] || [])].sort().join(',');
  const b = (serves.match(/\b[RW]\d\b/g) || []).sort().join(',');
  if (a !== b) fail(`${key}: catalog serves ${b}, the spec says ${a}`);
}
for (const { key } of ops) if (!seen.has(key)) fail(`spec operation is not in the catalog: ${key}`);
check(`the catalog matches the spec on all ${seen.size} endpoints (auth, success, errors, patterns)`, n);

// ---------- 6. Error catalog ----------
n = failures.length;
const FRAMEWORK_ONLY = new Set(['method_not_allowed']); // Cross-cutting, so not declared per operation.
const errSection = sectionOf(apiMd, '### 10.2');
const docCodes = new Map();
for (const line of errSection.split('\n')) {
  const m = line.match(/^\| `([a-z_]+)` \| (\d{3}) \|/);
  if (m) docCodes.set(m[1], Number(m[2]));
}
const specCodes = new Map(Object.values(spec.components.examples).map(e => [e.value.code, e.value.status]));
for (const [c, st] of specCodes) {
  if (!docCodes.has(c)) fail(`error ${c} is in the spec, but not in the api.md catalog`);
  else if (docCodes.get(c) !== st) fail(`error ${c}: api.md says ${docCodes.get(c)}, the spec says ${st}`);
}
for (const c of docCodes.keys()) if (!specCodes.has(c) && !FRAMEWORK_ONLY.has(c)) fail(`error ${c} is in api.md, but not in the spec`);
check(`the error catalog matches the spec (${docCodes.size} codes)`, n);

// ---------- 7. Cross-references ----------
n = failures.length;
const logged = new Set([...arch.matchAll(/^\| (D\d+) \|/gm)].map(m => m[1]));
const section14 = dbMd.slice(dbMd.indexOf('## 14. Amendments'));
for (const [name, text] of [['api.md', apiMd], ['openapi.yaml', specText], ['database.md section 14', section14]]) {
  for (const d of new Set([...text.matchAll(/\bD\d+\b/g)].map(m => m[0]))) {
    if (!logged.has(d)) fail(`${name} cites ${d}, which is not in the decision log`);
  }
}
for (const idx of new Set([...apiMd.matchAll(/\b(?:ix|uq|ex)_[a-z_]+\b/g)].map(m => m[0]))) {
  if (!dbMd.includes(idx)) fail(`api.md names index ${idx}, which is not in database.md`);
}
for (const m of apiMd.matchAll(/`(GET|PUT|POST|PATCH|DELETE) (\/[^`?\s]*)[^`]*`/g)) {
  if (!opByKey.has(`${m[1]} ${m[2]}`)) fail(`api.md mentions ${m[1]} ${m[2]}, which is not in the spec`);
}
if (!/docs\/design\/api\.md|design\/api\.md/.test(arch)) fail('ARCHITECTURE.md does not link to api.md');
if (!/docs\/api\/openapi\.yaml/.test(arch)) fail('ARCHITECTURE.md does not link to openapi.yaml');
check(`cross-references resolve (${logged.size} decisions in the log, indexes, endpoints, document links)`, n);

// ---------- 8. Bundling keeps every component ----------
// The root doesn't list components by name, so the bundler only keeps the ones something references.
n = failures.length;
const refs = new Set();
const collectRefs = x => {
  if (Array.isArray(x)) x.forEach(collectRefs);
  else if (x && typeof x === 'object') {
    for (const [k, v] of Object.entries(x)) {
      if (k === '$ref' && typeof v === 'string') refs.add(v);
      else collectRefs(v);
    }
  }
};
collectRefs(spec);
let componentCount = 0;
for (const [group, items] of Object.entries(spec.components)) {
  if (group === 'securitySchemes') continue;
  for (const name of Object.keys(items)) {
    componentCount++;
    if (!refs.has(`#/components/${group}/${name}`)) fail(`component ${group}/${name} is not referenced, so the bundle would drop it`);
  }
}
check(`all ${componentCount} components are referenced, so the bundle keeps them`, n);

if (failures.length) {
  console.log('\nProblems:');
  for (const f of failures) console.log(` - ${f}`);
}
console.log(`\noperations=${ops.length} examples=${exampleCount} failed=${failures.length}`);
process.exit(failures.length ? 1 : 0);

function sectionOf(text, heading) {
  const start = text.indexOf(`\n${heading}`);
  if (start < 0) { fail(`api.md has no section "${heading}"`); return ''; }
  const level = heading.match(/^#+/)[0];
  const rest = text.slice(start + 1);
  const next = rest.slice(heading.length).search(new RegExp(`\\n${level} `));
  return next < 0 ? rest : rest.slice(0, heading.length + next);
}
