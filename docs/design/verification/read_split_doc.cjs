// Rebuilds a design document that is split into topic files, so that checks read its real text.
// docs/design/database.md is an index, and docs/design/database/*.md hold its other sections.
// The result is the index's preface, followed by every numbered section in numeric order.
// Each topic file's own title and header are left out. A file with no sibling folder is returned as is.
const fs = require('fs');
const path = require('path');

const NUMBERED = /^#{2,3} (\d+(?:\.\d+)?)[. ]/;

// Splits text at numbered headings outside code fences. An unnumbered heading stays with the
// section before it. The chunks concatenate back to the exact input.
function splitChunks(text) {
  const chunks = [];
  let preface = null;
  let start = 0;
  let inFence = false;
  let offset = 0;
  let key = null;
  const close = end => {
    if (key === null) preface = text.slice(start, end);
    else chunks.push({ key, text: text.slice(start, end) });
  };
  for (const line of text.split('\n')) {
    if (line.startsWith('```')) inFence = !inFence;
    const m = !inFence && line.match(NUMBERED);
    if (m) {
      close(offset);
      start = offset;
      key = m[1];
    }
    offset += line.length + 1;
  }
  close(text.length);
  return { preface: preface === null ? '' : preface, chunks };
}

function compareKeys(a, b) {
  const [a1, a2 = 0] = a.split('.').map(Number);
  const [b1, b2 = 0] = b.split('.').map(Number);
  return a1 - b1 || a2 - b2;
}

function readText(file) {
  return fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
}

function readSplitDoc(indexPath) {
  const dir = indexPath.replace(/\.md$/, '');
  const index = readText(indexPath);
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return index;
  const { preface, chunks } = splitChunks(index);
  const seen = new Set(chunks.map(c => c.key));
  for (const name of fs.readdirSync(dir).filter(n => n.endsWith('.md')).sort()) {
    const part = splitChunks(readText(path.join(dir, name)));
    if (!part.chunks.length) throw new Error(`${name} has no numbered section`);
    for (const c of part.chunks) {
      if (seen.has(c.key)) throw new Error(`Section ${c.key} appears twice (${name})`);
      seen.add(c.key);
      chunks.push(c);
    }
  }
  chunks.sort((a, b) => compareKeys(a.key, b.key));
  return preface + chunks.map(c => c.text).join('');
}

module.exports = { readSplitDoc, splitChunks, compareKeys };
