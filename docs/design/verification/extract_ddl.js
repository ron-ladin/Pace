// Extracts the initial-schema DDL from docs/design/database.md section 3, and applies the
// migration order from section 10.4, so the test exercises the document's real text.
const fs = require('fs');
const path = require('path');
const [, , docPath, outPath] = process.argv;
const doc = fs.readFileSync(docPath, 'utf8').replace(/\r\n/g, '\n');

const start = doc.indexOf('## 3. Schema');
const end = doc.indexOf('## 4. Indexes');
const section = doc.slice(start, end);
const blocks = [...section.matchAll(/```sql\n([\s\S]*?)```/g)].map(m => m[1]);
const statements = blocks.join('\n').split(/;\s*\n/).map(s => s.trim()).filter(Boolean);

const order = ['users', 'friendships', 'groups', 'group_members', 'group_invitations', 'runs',
  'competitions', 'competition_participants', 'competition_invitations'];
const tableOf = s => {
  let m = s.match(/^CREATE TABLE (\w+)/);
  if (m) return m[1];
  m = s.match(/^CREATE (?:UNIQUE )?INDEX \w+ ON (\w+)/);
  if (m) return m[1];
  throw new Error('Unrecognized statement: ' + s.slice(0, 80));
};
const out = ['CREATE EXTENSION IF NOT EXISTS btree_gist;'];
for (const t of order) {
  const mine = statements.filter(s => tableOf(s) === t);
  if (!mine.length) throw new Error('No DDL found for ' + t);
  out.push(...mine.map(s => s + ';'));
}
const unknown = statements.filter(s => !order.includes(tableOf(s)));
if (unknown.length) throw new Error('Unmapped: ' + unknown.join('\n'));
fs.writeFileSync(outPath, out.join('\n\n') + '\n');
console.log(`Extracted ${statements.length} statements from ${blocks.length} SQL blocks to ${path.basename(outPath)}`);
