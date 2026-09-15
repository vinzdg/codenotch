// Run with node --test test-codex-headline.cjs from windows/.
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const html = readFileSync(join(__dirname, 'codenotch/ui/notch.html'), 'utf8');
const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)];
for (const [, source] of scripts) new vm.Script(source);
const start = html.indexOf('function headlineOf(');
const end = html.indexOf('function staleOf(', start);
assert.ok(start >= 0 && end > start, 'production headline selector is present');
const context = vm.createContext({});
vm.runInContext(html.slice(start, end), context);
const pick = (windows, provider = 'codex') => context.headlineOf({ windows }, provider)?.id ?? null;

test('Codex headline selects core primary regardless of extra-window order', () => {
  assert.equal(pick([{ id: 'spark' }, { id: 'secondary' }, { id: 'primary' }]), 'primary');
});
test('Codex secondary can lead, but Spark/code review cannot substitute for core', () => {
  assert.equal(pick([{ id: 'spark' }, { id: 'secondary' }]), 'secondary');
  assert.equal(pick([{ id: 'spark' }, { id: 'code-review' }]), null);
  assert.equal(pick([]), null);
});
test('Other provider headline selection is unchanged', () => {
  assert.equal(pick([{ id: 'weekly_all' }, { id: 'session' }], 'claude'), 'session');
  assert.equal(pick([{ id: 'on_demand' }, { id: 'included' }], 'cursor'), 'included');
});
