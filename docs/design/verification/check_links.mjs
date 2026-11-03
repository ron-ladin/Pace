// Checks the documentation's cross-references: relative links and anchors, the decision log,
// D-numbers, topic-file headers and index coverage. It needs Node.js only, with no packages.
// Usage: node check_links.mjs <repository root>
// Exit code 0 means every check passed.
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.argv[2]);
const failures = [];
const fail = m => failures.push(m);
function check(name, before) {
  const added = failures.length - before;
  console.log(added === 0 ? `PASS ${name}` : `FAIL ${name}: ${added} problem(s)`);
}

const SKIP = new Set(['.git', 'node_modules', 'dist']);
const walk = dir => fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
  if (SKIP.has(e.name)) return [];
  const full = path.join(dir, e.name);
  return e.isDirectory() ? walk(full) : [full];
});
const rel = f => path.relative(root, f).replace(/\\/g, '/');
const read = f => fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
const files = walk(root);
const markdown = files.filter(f => f.endsWith('.md'));

// GitHub's heading anchors. Repeated headings get -1, -2 and so on.
const slug = heading => heading.trim().toLowerCase().replace(/`/g, '').replace(/[^a-z0-9 _-]/g, '').replace(/ /g, '-');
function anchorsOf(text) {
  const anchors = new Set();
  const counts = new Map();
  let inFence = false;
  for (const line of text.split('\n')) {
    if (line.startsWith('```')) inFence = !inFence;
    const m = !inFence && line.match(/^#{1,6} (.*)$/);
    if (!m) continue;
    const s = slug(m[1]);
    const n = counts.get(s) || 0;
    counts.set(s, n + 1);
    anchors.add(n ? `${s}-${n}` : s);
  }
  return anchors;
}
const LINK = /\[[^\]]*\]\(([^)\s]+)\)/g;
function linksOf(text) {
  const out = [];
  let inFence = false;
  text.split('\n').forEach((line, i) => {
    if (line.startsWith('```')) inFence = !inFence;
    if (!inFence) for (const m of line.matchAll(LINK)) out.push({ target: m[1], line: i + 1 });
  });
  return out;
}
// Returns null when the link resolves, otherwise the reason it doesn't.
function problemWith(target, fromFile, readTarget) {
  if (/^[a-z]+:/i.test(target)) return null;
  const [file, anchor] = target.split('#');
  const resolved = file ? path.resolve(path.dirname(fromFile), file) : fromFile;
  const text = readTarget(resolved);
  if (text === null) return `no file ${file}`;
  if (anchor && !anchorsOf(text).has(anchor)) return `no anchor #${anchor} in ${rel(resolved)}`;
  return null;
}
const readIfExists = f => (fs.existsSync(f) && fs.statSync(f).isFile() ? read(f) : null);

// ---------- 1. Negative controls ----------
let n = failures.length;
if (slug('9. Milestone: async scoring via Outbox + queue (deferred)') !== '9-milestone-async-scoring-via-outbox--queue-deferred') fail('slug: punctuation');
if (slug('### 3.1 `users`'.replace(/^#+ /, '')) !== '31-users') fail('slug: code span');
const fake = f => (f.endsWith('real.md') ? '## 1. A heading\n' : null);
const from = path.join(root, 'from.md');
if (problemWith('real.md#1-a-heading', from, fake)) fail('negative control: a good link was refused');
if (!problemWith('real.md#2-missing', from, fake)) fail('negative control: a broken anchor was accepted');
if (!problemWith('missing.md', from, fake)) fail('negative control: a missing file was accepted');
check('the link resolver accepts a good link, and rejects a broken anchor and a missing file', n);

// ---------- 2. Links and anchors ----------
n = failures.length;
let linkCount = 0;
let anchorCount = 0;
for (const f of markdown) {
  for (const { target, line } of linksOf(read(f))) {
    if (/^[a-z]+:/i.test(target)) continue;
    linkCount++;
    if (target.includes('#')) anchorCount++;
    const problem = problemWith(target, f, readIfExists);
    if (problem) fail(`${rel(f)}:${line}: ${target}: ${problem}`);
  }
}
check(`all ${linkCount} relative links resolve in ${markdown.length} Markdown files, including ${anchorCount} anchors`, n);

// ---------- 3. Decision log ----------
n = failures.length;
const archFile = path.join(root, 'ARCHITECTURE.md');
const rows = [...read(archFile).matchAll(/^\| (D\d+) \|(.*)\|$/gm)];
const logged = new Set(rows.map(r => r[1]));
rows.forEach((r, i) => {
  if (r[1] !== `D${i + 1}`) fail(`decision log row ${i + 1} is ${r[1]}`);
  const lastCell = r[2].split('|').pop();
  const links = [...lastCell.matchAll(LINK)];
  if (links.length !== 1) fail(`${r[1]}: expected one link in the last column, found ${links.length}`);
  else if (!links[0][1].includes('#')) fail(`${r[1]}: the link names no section`);
  else {
    const problem = problemWith(links[0][1], archFile, readIfExists);
    if (problem) fail(`${r[1]}: ${problem}`);
  }
});
if (rows.length < 65) fail(`only ${rows.length} decisions were parsed`);
check(`all ${rows.length} decisions in the log are numbered without gaps, and each links to a section`, n);

// ---------- 4. Every D-number exists ----------
n = failures.length;
let citations = 0;
const TEXT = /\.(md|ya?ml|sql|js|cjs|mjs)$/;
for (const f of files.filter(x => TEXT.test(x))) {
  for (const m of read(f).matchAll(/\bD\d+\b/g)) {
    citations++;
    if (!logged.has(m[0])) fail(`${rel(f)} cites ${m[0]}, which is not in the decision log`);
  }
}
check(`all ${citations} D-number citations exist in the log`, n);

// ---------- 5. Topic files have headers, and their indexes list them ----------
n = failures.length;
let topicCount = 0;
for (const doc of ['database', 'api', 'classes']) {
  const index = read(path.join(root, 'docs/design', `${doc}.md`));
  for (const name of fs.readdirSync(path.join(root, 'docs/design', doc))) {
    topicCount++;
    const text = read(path.join(root, 'docs/design', doc, name));
    for (const label of ['Covers', 'Read when', 'Related']) {
      if (!text.includes(`\n> **${label}:**`)) fail(`${doc}/${name}: no ${label} header`);
    }
    if (!index.includes(`](${doc}/${name}`)) fail(`${doc}.md does not list ${name}`);
  }
}
check(`all ${topicCount} topic files have a header and are listed in their index`, n);

// ---------- 6. Contract files ----------
n = failures.length;
const apiDir = path.join(root, 'docs/api');
const yamlFiles = ['paths', 'components'].flatMap(d => fs.readdirSync(path.join(apiDir, d)).map(x => path.join(apiDir, d, x)));
for (const f of yamlFiles) {
  const text = read(f);
  for (const label of ['Covers', 'Read when', 'Related']) {
    if (!new RegExp(`^# ${label}: `, 'm').test(text)) fail(`${rel(f)}: no ${label} header`);
  }
  const related = text.match(/^# Related: (.*)$/m);
  for (const r of related ? related[1].split(', ') : []) {
    if (!fs.existsSync(path.resolve(path.dirname(f), r))) fail(`${rel(f)}: related file ${r} does not exist`);
  }
}
check(`all ${yamlFiles.length} contract files have a header, and their related files exist`, n);

// ---------- 7. ASCII ----------
n = failures.length;
for (const f of [...markdown, ...yamlFiles, path.join(apiDir, 'openapi.yaml')]) {
  if (/[^\x00-\x7F]/.test(read(f))) fail(`${rel(f)} contains non-ASCII characters`);
}
check('all documentation and contract files are ASCII', n);

if (failures.length) {
  console.log('\nProblems:');
  for (const f of failures) console.log(` - ${f}`);
}
console.log(`\nlinks=${linkCount} anchors=${anchorCount} decisions=${rows.length} citations=${citations} failed=${failures.length}`);
process.exit(failures.length ? 1 : 0);
