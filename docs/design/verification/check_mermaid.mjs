// Parses every Mermaid block in a Markdown file with the real Mermaid parser.
// A deliberately broken diagram is a negative control, proving that the parser can fail.
// Usage: node check_mermaid.mjs <directory with mermaid and jsdom installed> <markdown file>
// For a split document, pass its index: all of its topic files are checked.
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const pkgDir = path.resolve(process.argv[2]);
const docPath = path.resolve(process.argv[3]);
const require = createRequire(path.join(pkgDir, 'package.json'));
const { readSplitDoc } = createRequire(import.meta.url)('./read_split_doc.cjs');
const { JSDOM } = require('jsdom');
const dom = new JSDOM('<!doctype html><html><body></body></html>');
globalThis.window = dom.window;
globalThis.document = dom.window.document;
const entry = path.join(pkgDir, 'node_modules', 'mermaid', 'dist', 'mermaid.core.mjs');
const mermaid = (await import(pathToFileURL(entry).href)).default;

const doc = readSplitDoc(docPath);
const blocks = [...doc.matchAll(/```mermaid\n([\s\S]*?)```/g)].map(m => m[1]);
let failed = 0;
for (const [i, b] of blocks.entries()) {
  try {
    await mermaid.parse(b);
    console.log(`PASS block ${i + 1}: ${b.split('\n')[0]}`);
  } catch (e) {
    failed++;
    console.log(`FAIL block ${i + 1}: ${String(e.message).slice(0, 300)}`);
  }
}
try {
  await mermaid.parse('flowchart LR\n  A[[[ --> |broken');
  console.log('NEGATIVE CONTROL FAILED: broken diagram was accepted');
  failed++;
} catch {
  console.log('PASS negative control: broken diagram was rejected');
}
console.log(`blocks=${blocks.length} failed=${failed}`);
process.exit(failed ? 1 : 0);
