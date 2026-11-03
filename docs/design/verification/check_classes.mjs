// Checks docs/design/classes.md against the contract and the other design documents.
// It checks consistency between documents only. No code exists, so it proves nothing about behavior.
// Usage: node check_classes.mjs <directory with yaml installed> <repository root>
// Exit code 0 means every check passed.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const depsDir = path.resolve(process.argv[2]);
const root = path.resolve(process.argv[3]);
const require = createRequire(path.join(depsDir, 'package.json'));
const YAML = require('yaml');
const localRequire = createRequire(import.meta.url);
const { readSplitDoc } = localRequire('./read_split_doc.cjs');
const { loadSpec } = localRequire('../../api/verification/load_spec.cjs');

const read = p => readSplitDoc(path.join(root, p));
const doc = read('docs/design/classes.md');
const { spec } = loadSpec(YAML, path.join(root, 'docs/api'));
const apiMd = read('docs/design/api.md');
const dbMd = read('docs/design/database.md');
const arch = read('ARCHITECTURE.md');

const failures = [];
const fail = m => failures.push(m);
function check(name, before) {
  const added = failures.length - before;
  console.log(added === 0 ? `PASS ${name}` : `FAIL ${name}: ${added} problem(s)`);
}

function sectionOf(text, heading) {
  const start = text.indexOf(`\n${heading}`);
  if (start < 0) { fail(`no section "${heading}"`); return ''; }
  const level = heading.match(/^#+/)[0];
  const rest = text.slice(start + 1);
  const next = rest.slice(heading.length).search(new RegExp(`\\n#{1,${level.length}} `));
  return next < 0 ? rest : rest.slice(0, heading.length + next);
}
const cells = line => line.replace(/\\\|/g, '\u0000').split('|').slice(1, -1).map(c => c.trim().replace(/\u0000/g, '|'));
const rowsOf = text => text.split('\n').filter(l => l.startsWith('|') && !/^\|[-\s|]+\|$/.test(l)).map(cells);
const ticks = s => [...s.matchAll(/`([^`]+)`/g)].map(m => m[1]);

// ---------- 1. Module graph is acyclic ----------
function findCycle(graph) {
  const state = new Map();
  const visit = (n, trail) => {
    if (state.get(n) === 'done') return null;
    if (state.get(n) === 'open') return [...trail, n];
    state.set(n, 'open');
    for (const m of graph.get(n) || []) {
      const c = visit(m, [...trail, n]);
      if (c) return c;
    }
    state.set(n, 'done');
    return null;
  };
  for (const n of graph.keys()) {
    const c = visit(n, []);
    if (c) return c;
  }
  return null;
}
let n = failures.length;
const EXPECTED_MODULES = ['platform', 'identity', 'social', 'runs', 'competitions', 'leaderboards'];
const graph = new Map();
for (const r of rowsOf(sectionOf(doc, '### 2.2 '))) {
  if (r.length === 2 && r[0].startsWith('`')) graph.set(ticks(r[0])[0], ticks(r[1]));
}
for (const m of EXPECTED_MODULES) if (!graph.has(m)) fail(`module ${m} is missing from the dependency table`);
const cycle = findCycle(graph);
if (cycle) fail(`module cycle: ${cycle.join(' -> ')}`);
if (!findCycle(new Map([['a', ['b']], ['b', ['a']]]))) fail('negative control: a cyclic graph was accepted');
// Every module's edges must point strictly down the chain.
const chain = ['platform', 'identity', 'social', 'runs', 'competitions', 'leaderboards'];
for (const [m, deps] of graph) for (const d of deps) {
  if (chain.indexOf(d) >= chain.indexOf(m)) fail(`edge ${m} -> ${d} does not point down the chain`);
}
check(`the module graph has ${graph.size} modules and no cycle (negative control rejected)`, n);

// ---------- 2. Class inventory: every row has a responsibility ----------
n = failures.length;
const inventory = sectionOf(doc, '## 3. ');
const classes = new Set();
let rowCount = 0;
for (const r of rowsOf(inventory)) {
  if (r.length !== 7 || r[0] === 'Class') continue;
  rowCount++;
  const names = ticks(r[0]);
  if (!names.length) fail(`inventory row has no class name: ${r[0]}`);
  for (const name of names) classes.add(name);
  if (!r[1]) fail(`${r[0]}: no kind and visibility`);
  if (!/\b(pub|pp)\b/.test(r[1])) fail(`${r[0]}: kind column names no visibility`);
  if (r[2].length < 15) fail(`${r[0]}: no one-sentence responsibility`);
  if (/ and also /.test(r[2])) fail(`${r[0]}: responsibility looks like two jobs`);
}
if (rowCount < 100) fail(`only ${rowCount} inventory rows were parsed`);
check(`all ${rowCount} inventory rows (${classes.size} named types) have a kind, visibility and responsibility`, n);

// ---------- 3. Every endpoint has a home ----------
const METHODS = ['get', 'put', 'post', 'patch', 'delete'];
const specOps = [];
for (const [p, item] of Object.entries(spec.paths)) for (const m of METHODS) if (item[m]) specOps.push(`${m.toUpperCase()} ${p}`);
n = failures.length;
const endpointRows = rowsOf(sectionOf(doc, '### 14.1 ')).filter(r => /^`(GET|PUT|POST|PATCH|DELETE) /.test(r[0]));
const traced = new Set();
const classOf = ref => ref.split('.')[0];
for (const r of endpointRows) {
  const key = ticks(r[0])[0];
  if (traced.has(key)) fail(`${key}: listed twice`);
  traced.add(key);
  if (r.length !== 5) { fail(`${key}: expected 5 columns, found ${r.length}`); continue; }
  const [, controller, service, repo, dbItem] = r;
  for (const col of [controller, service, repo]) {
    if (!ticks(col).length) fail(`${key}: an empty column`);
    for (const ref of ticks(col)) {
      if (!ref.includes('.')) fail(`${key}: ${ref} is not a Class.method reference`);
      if (!classes.has(classOf(ref))) fail(`${key}: ${classOf(ref)} is not in the inventory`);
    }
  }
  if (!/^[\d., ]+$/.test(dbItem)) fail(`${key}: no database item`);
  for (const item of dbItem.split(',').map(s => s.trim())) {
    const section = item.split('.')[0];
    const heading = new RegExp(`^#{2,3} ${section}\\.`, 'm');
    const sub = new RegExp(`^#{2,3} ${item.replace('.', '\\.')}\\b`, 'm');
    if (!heading.test(dbMd) || !sub.test(dbMd)) fail(`${key}: database item ${item} does not exist`);
  }
}
for (const key of specOps) if (!traced.has(key)) fail(`spec operation has no home: ${key}`);
for (const key of traced) if (!specOps.includes(key)) fail(`traced endpoint is not in the spec: ${key}`);
check(`all ${specOps.length} operations have a controller, service, repository and database item`, n);

// Each repository method referenced by the endpoint table must appear in the persistence section.
n = failures.length;
const persistence = sectionOf(doc, '## 7. ');
let repoRefs = 0;
for (const r of endpointRows) for (const ref of ticks(r[3])) {
  repoRefs++;
  const method = ref.split('.')[1];
  if (!new RegExp(`\\b${method}\\(`).test(persistence)) fail(`${ref} is not defined in section 7`);
}
check(`all ${repoRefs} repository references in the endpoint table are defined in section 7`, n);

// ---------- 4. Access patterns ----------
n = failures.length;
const PATTERNS = ['R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'W1', 'W2', 'W3', 'W4', 'W5', 'W6'];
const patternRows = new Map(rowsOf(sectionOf(doc, '### 14.2 ')).map(r => [r[0], r[1]]));
for (const p of PATTERNS) {
  if (!patternRows.has(p)) { fail(`pattern ${p} has no owner`); continue; }
  for (const ref of ticks(patternRows.get(p))) if (!classes.has(classOf(ref))) fail(`${p}: ${classOf(ref)} is not in the inventory`);
}
check(`every R1-R8 and W1-W6 pattern has an owner in the inventory`, n);

// ---------- 5. Every race in the other documents has an owner ----------
n = failures.length;
const raceSection = sectionOf(doc, '### 14.3 ');
const racesInDoc = new Set(rowsOf(raceSection).filter(r => r.length === 3).map(r => r[1]));
// Only tables whose header starts with "Race" count.
function raceTable(text, heading) {
  const lines = sectionOf(text, heading).split('\n');
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (/^\| Race( or failure)? \|/.test(lines[i])) {
      for (let j = i + 2; lines[j] && lines[j].startsWith('|'); j++) out.push(cells(lines[j])[0]);
    }
  }
  return out;
}
const expectedRaces = [
  ...raceTable(dbMd, '### 6.3 '), ...raceTable(dbMd, '### 6.4 '), ...raceTable(dbMd, '### 6.5 '), ...raceTable(dbMd, '### 6.6 '),
  ...raceTable(apiMd, '### 11.4 '),
];
if (expectedRaces.length < 20) fail(`only ${expectedRaces.length} races were parsed from the other documents`);
for (const race of expectedRaces) if (!racesInDoc.has(race)) fail(`race has no owner: ${race}`);
check(`all ${expectedRaces.length} races in database.md section 6 and api.md 11.4 have an owner`, n);

n = failures.length;
const tests = [...sectionOf(dbMd, '### 11.3 ').matchAll(/^(\d+)\. /gm)].map(m => m[1]);
const testRows = new Set(rowsOf(raceSection).filter(r => /^\d+$/.test(r[0])).map(r => r[0]));
for (const t of tests) if (!testRows.has(t)) fail(`race test ${t} has no owner`);
if (tests.length !== 16) fail(`expected 16 race tests, found ${tests.length}`);
check(`all ${tests.length} required race tests have an owner`, n);

// ---------- 6. Every transaction section is covered ----------
n = failures.length;
const txRows = rowsOf(raceSection).filter(r => r.length === 4 && /^[\d., ]+$/.test(r[0]));
const txItems = new Set(txRows.flatMap(r => r[0].split(',').map(s => s.trim())));
for (const item of ['6.3', '6.4', '6.5', '6.6', '8.2', '8.3', '14.1', '14.4', '14.6', '3.5']) {
  if (!txItems.has(item)) fail(`database item ${item} has no transaction owner`);
}
for (const r of txRows) for (const ref of ticks(r[2])) if (!classes.has(classOf(ref))) fail(`transaction owner ${classOf(ref)} is not in the inventory`);
for (const lifecycle of ['Group role change', 'Group kick', 'Group leave', 'Create competition', 'Delete competition']) {
  if (!txRows.some(r => r[1] === lifecycle)) fail(`API-6 transaction has no owner: ${lifecycle}`);
}
check(`every transaction in database.md has an owner (${txRows.length} rows)`, n);

// ---------- 7. Decisions ----------
n = failures.length;
const logged = new Set([...arch.matchAll(/^\| (D\d+) \|/gm)].map(m => m[1]));
const decisionRows = rowsOf(sectionOf(doc, '### 14.4 ')).filter(r => /^D\d+$/.test(r[0]));
const covered = new Set(decisionRows.map(r => r[0]));
for (const d of logged) if (!covered.has(d)) fail(`decision ${d} is not in the decision table`);
for (const d of covered) if (!logged.has(d)) fail(`decision table lists ${d}, which is not in the log`);
for (const r of decisionRows) if (!r[1]) fail(`${r[0]}: no location`);
for (const d of new Set([...doc.matchAll(/\bD\d+\b/g)].map(m => m[0]))) if (!logged.has(d)) fail(`classes.md cites ${d}, which is not in the log`);
const numbers = [...logged].map(d => Number(d.slice(1))).sort((a, b) => a - b);
numbers.forEach((v, i) => { if (v !== i + 1) fail(`the decision log has a gap at D${i + 1}`); });
check(`all ${logged.size} decisions are in the table, and every cited D-number exists`, n);

// ---------- 8. DTO fields match the schemas ----------
n = failures.length;
const schemas = spec.components.schemas;
const deref = s => (s && s.$ref ? schemas[s.$ref.split('/').pop()] : s);
function propsOf(schema) {
  const s = deref(schema);
  if (!s) return null;
  const out = new Set(Object.keys(s.properties || {}));
  for (const part of s.allOf || []) for (const k of propsOf(part) || []) out.add(k);
  return out;
}
function resolvePath(p) {
  const [head, ...rest] = p.split('.');
  let s = schemas[head];
  for (const part of rest) {
    s = deref(s);
    const flat = [s, ...(s.allOf || []).map(deref)];
    const found = flat.map(f => f && f.properties && f.properties[part]).find(Boolean);
    if (!found) return null;
    s = found;
  }
  return s;
}
const dtoSection = sectionOf(doc, '### 16.1 ');
const dtoRows = rowsOf(dtoSection).filter(r => r.length === 3 && r[0] !== 'Schema path');
const dtoSeen = new Set();
let fieldCount = 0;
for (const [p, , fields] of dtoRows) {
  dtoSeen.add(p);
  const schema = resolvePath(p);
  if (!schema) { fail(`${p}: not found in the spec`); continue; }
  const want = propsOf(schema);
  const have = new Set(fields.split(',').map(s => s.trim()).filter(Boolean));
  fieldCount += have.size;
  for (const f of have) if (!want.has(f)) fail(`${p}: ${f} is not in the schema`);
  for (const f of want) if (!have.has(f)) fail(`${p}: schema field ${f} is missing from the table`);
}
const nonObjects = new Set(rowsOf(dtoSection).filter(r => r.length === 2 && r[0] !== 'Schema').map(r => r[0]));
for (const name of Object.keys(schemas)) {
  if (!dtoSeen.has(name) && !nonObjects.has(name)) fail(`schema ${name} is not mapped to a Java type`);
}
if (dtoRows.length < 30) fail(`only ${dtoRows.length} DTO rows were parsed`);
const fake = propsOf({ allOf: [{ properties: { a: {} } }, { properties: { b: {} } }] });
if (!(fake.has('a') && fake.has('b'))) fail('negative control: allOf was not flattened');
check(`all ${Object.keys(schemas).length} schemas are mapped, and ${fieldCount} fields match the spec (negative control passed)`, n);

// ---------- 9. Error codes ----------
n = failures.length;
const catalog = [...sectionOf(apiMd, '### 10.2').matchAll(/^\| `([a-z_]+)` \| \d{3} \|/gm)].map(m => m[1]);
const raised = new Map(rowsOf(sectionOf(doc, '### 9.3 ')).filter(r => r.length === 2 && r[0].startsWith('`')).map(r => [ticks(r[0])[0], r[1]]));
if (catalog.length !== 34) fail(`expected 34 codes in the catalog, found ${catalog.length}`);
for (const c of catalog) if (!raised.has(c)) fail(`error code ${c} has no raiser`);
for (const c of raised.keys()) if (!catalog.includes(c)) fail(`table lists ${c}, which is not in the catalog`);
for (const [c, who] of raised) for (const ref of ticks(who)) {
  if (!classes.has(classOf(ref))) fail(`${c}: ${classOf(ref)} is not in the inventory`);
}
check(`all ${catalog.length} error codes have a named raiser`, n);

// ---------- 10. Diagrams, schema names and cross-references ----------
n = failures.length;
const blocks = [...doc.matchAll(/```mermaid\n([\s\S]*?)```/g)].map(m => m[1]);
let participants = 0;
const NON_CLASS = new Set(['Browser', 'Controller', 'GroupController or GroupMemberController', 'GroupService or GroupMembershipService']);
for (const b of blocks) {
  for (const m of b.matchAll(/participant \w+ as (.+)/g)) {
    participants++;
    if (!NON_CLASS.has(m[1].trim()) && !classes.has(m[1].trim())) fail(`sequence diagram names ${m[1].trim()}, which is not in the inventory`);
  }
  for (const m of b.matchAll(/^\s*class (\w+)/gm)) if (!classes.has(m[1])) fail(`class diagram names ${m[1]}, which is not in the inventory`);
}
const REQUIRED_FLOWS = ['Run ingest', 'Join competition', 'Leave competition', 'Closure scheduler', 'Account deletion, phase 1', 'Account deletion, phase 2', 'Login', 'Session validation', 'Leaderboard', 'Group role change', 'Group create, join and delete', 'Create competition', 'Delete competition'];
const flows = sectionOf(doc, '## 8. ');
for (const f of REQUIRED_FLOWS) if (!new RegExp(`^### 8\\.\\d+ ${f}`, 'm').test(flows)) fail(`no flow section for ${f}`);
const flowBlocks = [...flows.matchAll(/```mermaid/g)].length;
if (flowBlocks !== REQUIRED_FLOWS.length) fail(`expected ${REQUIRED_FLOWS.length} flow diagrams, found ${flowBlocks}`);
for (const idx of new Set([...doc.matchAll(/\b(?:ix|uq|ex|ck)_[a-z_]+\b/g)].map(m => m[0]))) {
  if (!dbMd.includes(idx)) fail(`classes.md names ${idx}, which is not in database.md`);
}
for (const m of doc.matchAll(/`(GET|PUT|POST|PATCH|DELETE) (\/[^`?\s]*)[^`]*`/g)) {
  if (!specOps.includes(`${m[1]} ${m[2]}`)) fail(`classes.md mentions ${m[1]} ${m[2]}, which is not in the spec`);
}
for (const m of doc.matchAll(/\bCLS-(\d+)\b/g)) {
  if (!dbMd.includes(`| CLS-${m[1]} |`)) fail(`classes.md cites CLS-${m[1]}, which is not in database.md`);
}
if (!/docs\/design\/classes\.md/.test(arch)) fail('ARCHITECTURE.md does not link to classes.md');
if (/[^\x00-\x7F]/.test(doc)) fail('classes.md contains non-ASCII characters');
check(`${blocks.length} diagrams and ${participants} participants name real classes, ${REQUIRED_FLOWS.length} flows exist, and cross-references resolve`, n);

if (failures.length) {
  console.log('\nProblems:');
  for (const f of failures) console.log(` - ${f}`);
}
console.log(`\nclasses=${classes.size} operations=${specOps.length} failed=${failures.length}`);
process.exit(failures.length ? 1 : 0);
