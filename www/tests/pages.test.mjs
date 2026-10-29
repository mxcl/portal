import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
const root = resolve(import.meta.dirname, '../..');
for (const route of ['portal', 'portal/security', 'portal/privacy']) {
  const html = readFileSync(resolve(root, route, 'index.html'), 'utf8');
  assert.match(html, /<title>Portal/);
  for (const match of html.matchAll(/(?:src|href|poster)="(\/portal\/[^"?#]*)(?:[?#][^"]*)?"/g)) {
    assert.ok(existsSync(resolve(root, '.' + match[1])), `Missing published asset: ${match[1]}`);
  }
}
console.log('Portal landing, security, privacy, and local assets verified.');
