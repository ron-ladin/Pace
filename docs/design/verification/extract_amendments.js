// Extracts the migration SQL from docs/design/database.md section 14, so the test exercises the
// document's real text. A migration block is an sql block whose first line is "-- V0...".
const fs = require('fs');
const path = require('path');
const [, , docPath, outPath] = process.argv;
const { readSplitDoc } = require('./read_split_doc.cjs');
const doc = readSplitDoc(docPath);

const section = doc.slice(doc.indexOf('## 14. Amendments'));
const blocks = [...section.matchAll(/```sql\n(-- V\d{4}__[\s\S]*?)```/g)].map(m => m[1]);
if (blocks.length !== 2) throw new Error(`Expected 2 migration blocks, found ${blocks.length}`);
fs.writeFileSync(outPath, blocks.join('\n'));
console.log(`Extracted ${blocks.length} migration blocks to ${path.basename(outPath)}`);
